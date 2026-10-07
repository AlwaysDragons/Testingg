"""Initial listing price computation.

Target = max(cost × (1 + floor_margin_pct/100), p25 × 1.02)

- Reads the SKU's active supplier source min price for cost
- Reads market_listings p25 of recent SOLD rows for anchor
- Falls back to 1.5× cost if we have no sold data
"""
from __future__ import annotations

import datetime as dt
import statistics
from decimal import Decimal

from sqlalchemy import func, select

from src.config import settings
from src.db.models import MarketListing, ProductSource
from src.db.session import session_scope


async def compute_initial_price(sku: str, platform: str) -> Decimal | None:
    floor_mult = Decimal("1") + Decimal(settings.reprice_floor_margin_pct) / Decimal("100")
    async with session_scope() as sess:
        cost = (
            await sess.execute(
                select(func.min(ProductSource.expected_price_usd)).where(
                    ProductSource.sku == sku,
                    ProductSource.status == "active",
                )
            )
        ).scalar_one_or_none()
        if cost is None:
            return None

        since = dt.datetime.now(tz=dt.timezone.utc) - dt.timedelta(days=30)
        prices = [
            p for (p,) in (
                await sess.execute(
                    select(MarketListing.price_usd).where(
                        MarketListing.matched_sku == sku,
                        MarketListing.platform == platform,
                        MarketListing.sold.is_(True),
                        MarketListing.sold_at >= since,
                        MarketListing.price_usd.is_not(None),
                    )
                )
            ).all()
        ]

    floor = (cost * floor_mult).quantize(Decimal("0.01"))
    if not prices:
        return (cost * Decimal("1.5")).quantize(Decimal("0.01")).max(floor)
    sorted_prices = sorted(float(p) for p in prices)
    k = max(0, int(len(sorted_prices) * 0.25) - 1)
    p25 = Decimal(str(sorted_prices[k]))
    anchor = (p25 * Decimal("1.02")).quantize(Decimal("0.01"))
    return anchor.max(floor)
