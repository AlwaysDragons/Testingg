"""Pre-stocked inventory tracker + reshipper fulfillment hook.

When a sale lands for a SKU whose stocking_mode='prestocked', fulfill_order
hits this module. It picks an available inventory row, calls the configured
reshipper, decrements qty, records tracking on the supplier_order.
"""
from __future__ import annotations

import datetime as dt

from loguru import logger
from sqlalchemy import select, update

from src.config import settings
from src.db.models import PrestockedInventory, Sale
from src.db.queries import update_supplier_order
from src.db.session import session_scope
from src.reshipper.base import ReshipperBase
from src.reshipper.shipito import Shipito


def _reshipper() -> ReshipperBase:
    if settings.reshipper == "shipito":
        return Shipito()
    raise ValueError(f"unknown reshipper: {settings.reshipper}")


async def _pick_inventory(sku: str, size: str | None) -> PrestockedInventory | None:
    async with session_scope() as sess:
        stmt = (
            select(PrestockedInventory)
            .where(PrestockedInventory.sku == sku, PrestockedInventory.qty_available > 0)
            .order_by(PrestockedInventory.received_at.asc())
        )
        if size:
            stmt = stmt.where(PrestockedInventory.size == size)
        row = (await sess.execute(stmt)).scalars().first()
        return row


async def _consume_one(inv_id: int) -> None:
    async with session_scope() as sess:
        await sess.execute(
            update(PrestockedInventory)
            .where(PrestockedInventory.id == inv_id)
            .values(
                qty_available=PrestockedInventory.qty_available - 1,
                last_sold=dt.datetime.now(tz=dt.timezone.utc),
            )
        )


async def fulfill_from_reshipper(order_id: int, sale: Sale) -> None:
    if not sale.buyer_address:
        raise RuntimeError("no buyer address for reshipper fulfillment")

    sku = (
        (await _load_sku_from_order(order_id))
        if not getattr(sale, "sku", None)
        else sale.sku  # type: ignore[attr-defined]
    )
    size = sale.buyer_address.get("size")
    inv = await _pick_inventory(sku, size)
    if inv is None:
        logger.warning("prestock out of stock sku={} size={}", sku, size)
        await update_supplier_order(order_id, status="failed", error_log="prestock_oos")
        return

    rs = _reshipper()
    result = await rs.ship(item_id=inv.reshipper_item_id or "", buyer=sale.buyer_address)
    if not result.ok:
        await update_supplier_order(order_id, status="failed", error_log=result.error)
        return

    await _consume_one(inv.id)
    await update_supplier_order(
        order_id,
        source=rs.name,
        status="shipped",
        supplier_order_ref=result.reshipper_shipment_id,
        tracking_number=result.tracking_number,
        tracking_carrier=result.carrier,
        cost_usd=inv.unit_cost_landed_usd,
        shipped_at=dt.datetime.now(tz=dt.timezone.utc),
        placed_at=dt.datetime.now(tz=dt.timezone.utc),
    )
    logger.info(
        "prestock fulfillment ok order={} tracking={} carrier={}",
        order_id,
        result.tracking_number,
        result.carrier,
    )


async def _load_sku_from_order(order_id: int) -> str:
    from src.db.models import SupplierOrder

    async with session_scope() as sess:
        row = (
            await sess.execute(
                select(SupplierOrder.sku).where(SupplierOrder.id == order_id)
            )
        ).first()
        return row[0] if row else ""
