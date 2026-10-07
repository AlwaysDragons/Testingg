"""Common DB queries used by workers + Telegram handlers."""
from __future__ import annotations

import datetime as dt
from decimal import Decimal
from typing import Any

from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert

from src.db.models import (
    OurListing,
    PostingAccount,
    ProductCatalog,
    Sale,
    SupplierOrder,
)
from src.db.session import session_scope


async def active_posting_accounts(platform: str | None = None) -> list[PostingAccount]:
    async with session_scope() as sess:
        stmt = select(PostingAccount).where(PostingAccount.status == "active")
        if platform:
            stmt = stmt.where(PostingAccount.platform == platform)
        return list((await sess.execute(stmt)).scalars().all())


async def upsert_sale(
    *,
    platform: str,
    platform_sale_id: str,
    our_listing_id: int | None,
    buyer_handle: str | None,
    buyer_address: dict[str, Any] | None,
    sale_price_usd: Decimal | None,
    platform_fee_usd: Decimal | None,
    sold_at: dt.datetime | None,
) -> tuple[int, bool]:
    """Returns (sale_id, created_bool)."""
    async with session_scope() as sess:
        stmt = pg_insert(Sale.__table__).values(
            platform=platform,
            platform_sale_id=platform_sale_id,
            our_listing_id=our_listing_id,
            buyer_handle=buyer_handle,
            buyer_address=buyer_address,
            sale_price_usd=sale_price_usd,
            platform_fee_usd=platform_fee_usd,
            net_received_usd=(
                (sale_price_usd - platform_fee_usd)
                if sale_price_usd and platform_fee_usd
                else None
            ),
            sold_at=sold_at,
        )
        stmt = stmt.on_conflict_do_nothing(index_elements=["platform_sale_id"]).returning(
            Sale.id
        )
        result = await sess.execute(stmt)
        row = result.first()
        if row is not None:
            return int(row[0]), True

        existing = await sess.execute(
            select(Sale.id).where(Sale.platform_sale_id == platform_sale_id)
        )
        return int(existing.scalar_one()), False


async def set_sale_address(sale_id: int, address: dict[str, Any]) -> None:
    async with session_scope() as sess:
        await sess.execute(
            update(Sale).where(Sale.id == sale_id).values(buyer_address=address)
        )


async def find_our_listing_id(
    platform: str, platform_listing_id: str
) -> tuple[int | None, str | None]:
    """Returns (our_listing_id, sku) if matched else (None, None)."""
    async with session_scope() as sess:
        row = (
            await sess.execute(
                select(OurListing.id, OurListing.sku).where(
                    OurListing.platform == platform,
                    OurListing.platform_listing_id == platform_listing_id,
                )
            )
        ).first()
        if row is None:
            return None, None
        return int(row[0]), row[1]


async def get_sku_stocking_mode(sku: str) -> str | None:
    async with session_scope() as sess:
        row = (
            await sess.execute(
                select(ProductCatalog.stocking_mode).where(ProductCatalog.sku == sku)
            )
        ).first()
        return row[0] if row else None


async def create_supplier_order(
    *,
    sale_id: int,
    sku: str | None,
    source: str,
    status: str = "queued",
) -> int:
    async with session_scope() as sess:
        result = await sess.execute(
            SupplierOrder.__table__.insert()
            .values(sale_id=sale_id, sku=sku, source=source, status=status)
            .returning(SupplierOrder.id)
        )
        return int(result.scalar_one())


async def update_supplier_order(order_id: int, **fields: Any) -> None:
    async with session_scope() as sess:
        await sess.execute(
            update(SupplierOrder).where(SupplierOrder.id == order_id).values(**fields)
        )
