"""Fulfill a supplier_order row — pick driver, place order, record result."""
from __future__ import annotations

import asyncio
import datetime as dt

from loguru import logger
from sqlalchemy import select

from src.db.models import Sale, SupplierOrder
from src.db.queries import update_supplier_order
from src.db.session import session_scope
from src.suppliers.base import BuyerAddress, Variant
from src.suppliers.router import get_driver, mark_source_dead, route_order


async def _load_order(order_id: int) -> tuple[SupplierOrder, Sale] | None:
    async with session_scope() as sess:
        row = (
            await sess.execute(
                select(SupplierOrder, Sale)
                .join(Sale, Sale.id == SupplierOrder.sale_id)
                .where(SupplierOrder.id == order_id)
            )
        ).first()
        if row is None:
            return None
        return row[0], row[1]


def _buyer_from_address(address: dict) -> BuyerAddress:
    return BuyerAddress(
        recipient=address.get("recipient", ""),
        line1=address.get("line1", ""),
        line2=address.get("line2"),
        city=address.get("city", ""),
        state=address.get("state", ""),
        postal_code=address.get("postal_code", ""),
        country=address.get("country", "US"),
        phone=address.get("phone"),
    )


async def _run_async(order_id: int) -> None:
    pair = await _load_order(order_id)
    if pair is None:
        logger.error("fulfill_order: order {} not found", order_id)
        return
    order, sale = pair

    if order.status not in ("queued", "failed"):
        logger.info("fulfill_order {}: status={}, skipping", order_id, order.status)
        return
    if not sale.buyer_address:
        logger.warning("fulfill_order {}: no buyer address yet", order_id)
        return

    await update_supplier_order(order_id, status="placing", attempts=order.attempts + 1)

    if order.source == "reshipper":
        # Phase 7 path — hand to reshipper worker. Guarded until registered.
        from src.reshipper.stocking import fulfill_from_reshipper

        try:
            await fulfill_from_reshipper(order_id, sale)
        except Exception as exc:
            logger.exception("reshipper fulfillment failed: {}", exc)
            await update_supplier_order(order_id, status="failed", error_log=str(exc))
        return

    sku = order.sku
    if not sku:
        await update_supplier_order(order_id, status="failed", error_log="no SKU")
        return

    resolved = await route_order(sku, size=(sale.buyer_address or {}).get("size"))
    if resolved is None:
        await update_supplier_order(
            order_id, status="failed", error_log="no supplier source available"
        )
        logger.error("fulfill_order {}: no source for SKU {}", order_id, sku)
        return

    driver = get_driver(resolved.source)
    buyer = _buyer_from_address(sale.buyer_address)
    variant = Variant(color=resolved.color_option, size=resolved.size_option, qty=1)

    result = await driver.place_order(
        product_url=resolved.product_url,
        variant=variant,
        buyer=buyer,
        order_ref=f"MP-{sale.id}",
        max_price_usd=resolved.max_price_usd,
    )

    if not result.ok:
        err = result.error or "unknown"
        logger.error("fulfill_order {}: driver failed — {}", order_id, err)
        if err.startswith("stock_out") or err.startswith("price_breach"):
            await mark_source_dead(sku, resolved.source, resolved.product_url, err)
        await update_supplier_order(order_id, status="failed", error_log=err)
        return

    await update_supplier_order(
        order_id,
        status="placed",
        source=resolved.source,
        supplier_order_ref=result.supplier_order_ref,
        cost_usd=result.cost_usd,
        placed_at=dt.datetime.now(tz=dt.timezone.utc),
        error_log=None,
    )
    logger.info(
        "fulfill_order {} placed on {} ref={} cost={}",
        order_id,
        resolved.source,
        result.supplier_order_ref,
        result.cost_usd,
    )


def run(order_id: int) -> None:
    asyncio.run(_run_async(order_id))
