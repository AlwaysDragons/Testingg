"""Score each SKU as a current opportunity.

composite = (margin_usd / 10) * velocity_score / sqrt(1 + saturation_count)

- margin_usd      = median(market_price) - min(supplier source price)
- velocity_score  = sold-count last 30d
- saturation      = active listing count on all 3 platforms
Each knob is a signal, not a prescription. The script writes a row per SKU per
day; the daily digest reads top-N by composite_score.
"""
from __future__ import annotations

import datetime as dt
import math
import statistics
from decimal import Decimal

from loguru import logger
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from src.db.models import MarketListing, Opportunity, ProductCatalog, ProductSource
from src.db.session import session_scope


async def score_all_skus() -> int:
    async with session_scope() as sess:
        skus = [r[0] for r in (await sess.execute(select(ProductCatalog.sku))).all()]
        if not skus:
            return 0

        # Preload supplier mins per SKU
        src_rows = (
            await sess.execute(
                select(
                    ProductSource.sku,
                    func.min(ProductSource.expected_price_usd),
                ).where(ProductSource.status == "active")
                .group_by(ProductSource.sku)
            )
        ).all()
        supplier_min = {r[0]: r[1] for r in src_rows}

        thirty = dt.datetime.now(tz=dt.timezone.utc) - dt.timedelta(days=30)
        wrote = 0
        for sku in skus:
            prices = [
                p for (p,) in (
                    await sess.execute(
                        select(MarketListing.price_usd).where(
                            MarketListing.matched_sku == sku,
                            MarketListing.sold.is_(True),
                            MarketListing.sold_at >= thirty,
                            MarketListing.price_usd.is_not(None),
                        )
                    )
                ).all()
            ]
            saturation = int(
                (
                    await sess.execute(
                        select(func.count()).select_from(MarketListing).where(
                            MarketListing.matched_sku == sku,
                            MarketListing.sold.is_(False),
                        )
                    )
                ).scalar_one()
            )

            median_price = Decimal(str(statistics.median(prices))) if prices else None
            velocity = Decimal(len(prices))
            supplier_cost = supplier_min.get(sku)
            margin = (
                (median_price - supplier_cost)
                if (median_price is not None and supplier_cost is not None)
                else None
            )
            composite = None
            if margin is not None:
                composite = Decimal(
                    str(
                        (float(margin) / 10.0)
                        * float(velocity)
                        / math.sqrt(1.0 + float(saturation))
                    )
                ).quantize(Decimal("0.01"))

            recommended = (
                "scale"
                if composite is not None and composite >= Decimal("5")
                else "hold"
                if composite is not None and composite >= Decimal("1")
                else "kill"
            )

            stmt = pg_insert(Opportunity.__table__).values(
                sku=sku,
                market_price_median=median_price,
                supplier_cost_usd=supplier_cost,
                margin_usd=margin,
                velocity_score=velocity,
                saturation_count=saturation,
                composite_score=composite,
                recommended_action=recommended,
            )
            await sess.execute(stmt)
            wrote += 1

    logger.info("opportunity scoring: {} rows written", wrote)
    return wrote


async def top_opportunities(limit: int = 10) -> list[Opportunity]:
    async with session_scope() as sess:
        today = dt.datetime.now(tz=dt.timezone.utc).date()
        rows = (
            await sess.execute(
                select(Opportunity)
                .where(func.date(Opportunity.scored_at) == today)
                .order_by(Opportunity.composite_score.desc().nullslast())
                .limit(limit)
            )
        ).scalars().all()
        return list(rows)
