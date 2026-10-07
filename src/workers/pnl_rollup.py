"""Nightly P&L — write pnl_daily + pnl_sku_rollup."""
from __future__ import annotations

import asyncio
import datetime as dt
from decimal import Decimal

from loguru import logger
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from src.db.models import PnlDaily, PnlSkuRollup, Sale, SupplierOrder
from src.db.session import session_scope


async def _rollup_day(day: dt.date) -> None:
    start = dt.datetime.combine(day, dt.time.min, tzinfo=dt.timezone.utc)
    end = start + dt.timedelta(days=1)
    async with session_scope() as sess:
        rows = (
            await sess.execute(
                select(Sale, SupplierOrder)
                .join(SupplierOrder, SupplierOrder.sale_id == Sale.id, isouter=True)
                .where(Sale.sold_at >= start, Sale.sold_at < end)
            )
        ).all()
    gross = Decimal("0")
    fees = Decimal("0")
    supplier_costs = Decimal("0")
    sales_count = 0
    for sale, order in rows:
        if sale.sale_price_usd:
            gross += sale.sale_price_usd
            sales_count += 1
        if sale.platform_fee_usd:
            fees += sale.platform_fee_usd
        if order and order.cost_usd:
            supplier_costs += order.cost_usd
    net = gross - fees - supplier_costs

    async with session_scope() as sess:
        await sess.execute(
            pg_insert(PnlDaily.__table__)
            .values(
                date=day,
                sales_count=sales_count,
                gross_sales_usd=gross,
                platform_fees_usd=fees,
                supplier_costs_usd=supplier_costs,
                shipping_costs_usd=Decimal("0"),
                reshipper_fees_usd=Decimal("0"),
                chargebacks_usd=Decimal("0"),
                net_profit_usd=net,
            )
            .on_conflict_do_update(
                index_elements=["date"],
                set_={
                    "sales_count": sales_count,
                    "gross_sales_usd": gross,
                    "platform_fees_usd": fees,
                    "supplier_costs_usd": supplier_costs,
                    "net_profit_usd": net,
                    "computed_at": func.now(),
                },
            )
        )
    logger.info("pnl_daily {}: {} sales / gross {} / net {}", day, sales_count, gross, net)


async def _rollup_sku(period_days: int = 30) -> int:
    end = dt.date.today()
    start = end - dt.timedelta(days=period_days)
    async with session_scope() as sess:
        rows = (
            await sess.execute(
                select(
                    Sale.id,
                    SupplierOrder.sku,
                    Sale.sale_price_usd,
                    Sale.platform_fee_usd,
                    SupplierOrder.cost_usd,
                )
                .join(SupplierOrder, SupplierOrder.sale_id == Sale.id)
                .where(Sale.sold_at >= dt.datetime.combine(start, dt.time.min, tzinfo=dt.timezone.utc))
            )
        ).all()
    buckets: dict[str, dict] = {}
    for _sid, sku, gross, fee, cost in rows:
        if not sku:
            continue
        b = buckets.setdefault(sku, {"gross": Decimal("0"), "fees": Decimal("0"), "cost": Decimal("0"), "n": 0})
        if gross:
            b["gross"] += gross
            b["n"] += 1
        if fee:
            b["fees"] += fee
        if cost:
            b["cost"] += cost
    wrote = 0
    async with session_scope() as sess:
        for sku, b in buckets.items():
            net = b["gross"] - b["fees"] - b["cost"]
            margin_pct = (
                (net / b["gross"] * Decimal("100")).quantize(Decimal("0.01"))
                if b["gross"]
                else None
            )
            if margin_pct is None:
                rec = "hold"
            elif margin_pct >= Decimal("40"):
                rec = "scale"
            elif margin_pct >= Decimal("25"):
                rec = "hold"
            else:
                rec = "kill"
            await sess.execute(
                pg_insert(PnlSkuRollup.__table__)
                .values(
                    sku=sku,
                    period_start=start,
                    period_end=end,
                    sales_count=b["n"],
                    gross_usd=b["gross"],
                    cost_usd=b["cost"],
                    fees_usd=b["fees"],
                    net_usd=net,
                    avg_margin_pct=margin_pct,
                    recommendation=rec,
                )
                .on_conflict_do_update(
                    index_elements=["sku", "period_start", "period_end"],
                    set_={
                        "sales_count": b["n"],
                        "gross_usd": b["gross"],
                        "cost_usd": b["cost"],
                        "fees_usd": b["fees"],
                        "net_usd": net,
                        "avg_margin_pct": margin_pct,
                        "recommendation": rec,
                    },
                )
            )
            wrote += 1
    logger.info("pnl_sku_rollup: {} SKU rows", wrote)
    return wrote


async def _run_async() -> None:
    yesterday = dt.date.today() - dt.timedelta(days=1)
    await _rollup_day(yesterday)
    await _rollup_sku(30)


def run(*_args, **_kwargs) -> None:
    asyncio.run(_run_async())
