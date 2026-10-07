"""Supplier router.

For a given SKU, pick the best product_source: prefer DHgate (lower cost,
direct supplier), fall back to Hoobuy / Kakobuy (agents). Ranks by priority
asc, then expected_price_usd asc, filters out sources flagged dead.
"""
from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from loguru import logger
from sqlalchemy import select

from src.db.models import ProductSource
from src.db.session import session_scope
from src.suppliers.base import SupplierBase
from src.suppliers.dhgate import DHgate
from src.suppliers.hoobuy import Hoobuy
from src.suppliers.kakobuy import Kakobuy

_DRIVERS: dict[str, SupplierBase] = {
    "dhgate": DHgate(),
    "hoobuy": Hoobuy(),
    "kakobuy": Kakobuy(),
}


def get_driver(source: str) -> SupplierBase:
    if source not in _DRIVERS:
        raise ValueError(f"unknown supplier: {source}")
    return _DRIVERS[source]


@dataclass
class ResolvedSource:
    source: str
    product_url: str
    color_option: str | None
    size_option: str | None
    max_price_usd: Decimal | None


async def route_order(sku: str, size: str | None = None) -> ResolvedSource | None:
    """Pick the best live source for this SKU (optionally a specific size)."""
    async with session_scope() as sess:
        stmt = select(ProductSource).where(
            ProductSource.sku == sku,
            ProductSource.status == "active",
        )
        if size:
            stmt = stmt.where(
                (ProductSource.size_option == size) | (ProductSource.size_option.is_(None))
            )
        rows = (await sess.execute(stmt)).scalars().all()

    if not rows:
        logger.warning("router: no active sources for SKU {}", sku)
        return None

    source_pref = {"dhgate": 0, "hoobuy": 1, "kakobuy": 2}
    rows_sorted = sorted(
        rows,
        key=lambda r: (
            r.priority,
            source_pref.get(r.source, 99),
            r.expected_price_usd or Decimal("1000000"),
        ),
    )
    pick = rows_sorted[0]
    logger.info(
        "router -> {} for SKU {} (priority={}, price={})",
        pick.source,
        sku,
        pick.priority,
        pick.expected_price_usd,
    )
    return ResolvedSource(
        source=pick.source,
        product_url=pick.product_url,
        color_option=pick.color_option,
        size_option=pick.size_option,
        max_price_usd=pick.max_price_usd,
    )


async def mark_source_dead(sku: str, source: str, product_url: str, reason: str) -> None:
    """Mark a specific (sku, source, url) source as dead so the router skips it."""
    from sqlalchemy import update

    async with session_scope() as sess:
        await sess.execute(
            update(ProductSource)
            .where(
                ProductSource.sku == sku,
                ProductSource.source == source,
                ProductSource.product_url == product_url,
            )
            .values(status="dead")
        )
    logger.warning("source marked dead: {}/{} ({}): {}", sku, source, product_url, reason)
