"""Dynamic reprice — never reprice twice in 48h, never below cost × floor%."""
from __future__ import annotations

import datetime as dt
import statistics
from decimal import Decimal

from loguru import logger
from sqlalchemy import func, select, update

from src.config import settings
from src.db.models import MarketListing, OurListing, PostingAccount, ProductSource
from src.db.session import session_scope
from src.marketplaces.registry import get_marketplace


async def _compute_target(sku: str, platform: str) -> Decimal | None:
    async with session_scope() as sess:
        cost = (
            await sess.execute(
                select(func.min(ProductSource.expected_price_usd)).where(
                    ProductSource.sku == sku, ProductSource.status == "active"
                )
            )
        ).scalar_one_or_none()
        if cost is None:
            return None
        since = dt.datetime.now(tz=dt.timezone.utc) - dt.timedelta(hours=48)
        prices = [
            float(p) for (p,) in (
                await sess.execute(
                    select(MarketListing.price_usd).where(
                        MarketListing.matched_sku == sku,
                        MarketListing.platform == platform,
                        MarketListing.sold.is_(False),
                        MarketListing.scraped_at >= since,
                        MarketListing.price_usd.is_not(None),
                    )
                )
            ).all()
        ]
    floor = cost * (Decimal("1") + Decimal(settings.reprice_floor_margin_pct) / Decimal("100"))
    if not prices:
        return floor.quantize(Decimal("0.01"))
    srt = sorted(prices)
    p25 = Decimal(str(srt[max(0, int(len(srt) * 0.25) - 1)]))
    target = (p25 * Decimal("1.02")).quantize(Decimal("0.01"))
    return target.max(floor.quantize(Decimal("0.01")))


async def _reprice_one(listing: OurListing, account: PostingAccount) -> bool:
    if not listing.sku or not listing.platform_listing_id or not listing.price_usd:
        return False
    now = dt.datetime.now(tz=dt.timezone.utc)
    if listing.last_repriced_at and (now - listing.last_repriced_at).total_seconds() < 48 * 3600:
        return False
    target = await _compute_target(listing.sku, listing.platform)
    if target is None:
        return False
    diff_pct = abs((target - listing.price_usd) / listing.price_usd * Decimal("100"))
    if diff_pct < Decimal("5"):
        return False
    mp = get_marketplace(listing.platform)
    ok = await mp.update_listing_price(account, listing.platform_listing_id, float(target))
    if not ok:
        return False
    async with session_scope() as sess:
        await sess.execute(
            update(OurListing)
            .where(OurListing.id == listing.id)
            .values(price_usd=target, last_repriced_at=now)
        )
    logger.info(
        "repriced {}/{}: {} -> {} ({}%)", listing.platform, listing.platform_listing_id,
        listing.price_usd, target, diff_pct,
    )
    return True


async def _run_async() -> int:
    async with session_scope() as sess:
        rows = (
            await sess.execute(
                select(OurListing, PostingAccount)
                .join(PostingAccount, PostingAccount.id == OurListing.posting_account_id)
                .where(OurListing.status == "active")
            )
        ).all()
    reduced = 0
    for listing, account in rows:
        try:
            if await _reprice_one(listing, account):
                reduced += 1
        except Exception as exc:
            logger.exception("reprice {}: {}", listing.id, exc)
    logger.info("repricer: {} / {} listings adjusted", reduced, len(rows))
    return reduced


def run(*_args, **_kwargs) -> None:
    import asyncio

    asyncio.run(_run_async())
