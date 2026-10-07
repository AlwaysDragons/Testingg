"""Poll placed supplier orders for tracking, push to marketplace, mark pushed."""
from __future__ import annotations

import asyncio
import datetime as dt

from loguru import logger
from sqlalchemy import select

from src.db.models import PostingAccount, Sale, SupplierOrder
from src.db.queries import update_supplier_order
from src.db.session import session_scope
from src.marketplaces.registry import get_marketplace
from src.suppliers.router import get_driver


async def _pending_orders() -> list[tuple[SupplierOrder, Sale, PostingAccount | None]]:
    async with session_scope() as sess:
        rows = (
            await sess.execute(
                select(SupplierOrder, Sale, PostingAccount)
                .join(Sale, Sale.id == SupplierOrder.sale_id)
                .outerjoin(PostingAccount, PostingAccount.id == None)  # noqa: E711
                .where(
                    SupplierOrder.status.in_(["placed", "qc_approved", "shipped"]),
                    SupplierOrder.tracking_pushed.is_(False),
                )
            )
        ).all()
        results: list[tuple[SupplierOrder, Sale, PostingAccount | None]] = []
        for order, sale, _ in rows:
            acct = None
            if sale.our_listing_id is not None:
                from src.db.models import OurListing

                acct_row = (
                    await sess.execute(
                        select(PostingAccount)
                        .join(OurListing, OurListing.posting_account_id == PostingAccount.id)
                        .where(OurListing.id == sale.our_listing_id)
                    )
                ).scalar_one_or_none()
                acct = acct_row
            results.append((order, sale, acct))
        return results


async def _process(order: SupplierOrder, sale: Sale, account: PostingAccount | None) -> None:
    if not order.supplier_order_ref or order.source in (None, "reshipper", "router"):
        if order.source != "reshipper":
            return
    driver_name = order.source if order.source != "router" else None
    tracking = order.tracking_number
    carrier = order.tracking_carrier

    if not tracking:
        if order.source == "reshipper":
            # Reshipper flow set tracking at ship time; nothing to poll.
            return
        try:
            driver = get_driver(driver_name)  # type: ignore[arg-type]
        except Exception:
            return
        info = await driver.fetch_tracking(order.supplier_order_ref)
        tracking = info.get("tracking_number")
        carrier = info.get("carrier") or carrier
        if not tracking:
            return
        await update_supplier_order(
            order.id,
            tracking_number=tracking,
            tracking_carrier=carrier,
            status="shipped",
            shipped_at=dt.datetime.now(tz=dt.timezone.utc),
        )

    if account is None:
        logger.warning("tracking: no posting account for sale {}", sale.id)
        return

    mp = get_marketplace(sale.platform)
    ok = await mp.push_tracking(
        account, sale.platform_sale_id, tracking, carrier or "USPS"
    )
    if ok:
        await update_supplier_order(order.id, tracking_pushed=True)
        logger.info("tracking pushed for sale {} order {}", sale.id, order.id)


async def _run_async() -> None:
    rows = await _pending_orders()
    if not rows:
        return
    for row in rows:
        try:
            await _process(*row)
        except Exception as exc:
            logger.exception("tracking row failed: {}", exc)


def run(*_args, **_kwargs) -> None:
    asyncio.run(_run_async())
