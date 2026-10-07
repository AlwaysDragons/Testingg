"""Scrape monitored competitor sellers, diff for new/sold/price-drop, alert."""
from __future__ import annotations

import asyncio
import datetime as dt
from decimal import Decimal

import httpx
from loguru import logger
from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert

from src.config import settings
from src.db.models import CompetitorListing, CompetitorSeller
from src.db.session import session_scope
from src.scrapers import depop, grailed, mercari

_SCRAPERS = {"depop": depop.scrape_search, "grailed": grailed.scrape_search, "mercari": mercari.scrape_search}


async def _telegram_alert(text: str) -> None:
    if not settings.telegram_bot_token or not settings.telegram_chat_id:
        return
    try:
        async with httpx.AsyncClient(timeout=10) as c:
            await c.post(
                f"https://api.telegram.org/bot{settings.telegram_bot_token}/sendMessage",
                json={"chat_id": settings.telegram_chat_id, "text": text[:3900]},
            )
    except Exception:
        pass


async def _scan_seller(seller: CompetitorSeller) -> None:
    scraper = _SCRAPERS.get(seller.platform)
    if scraper is None:
        return
    categories = seller.categories or ["streetwear"]
    seen_ids: set[str] = set()
    for cat in categories[:3]:
        try:
            batch = await scraper(cat, pages=1, sold=False)
        except Exception as exc:
            logger.exception("competitor scan {}/{}: {}", seller.platform, cat, exc)
            continue
        for item in batch:
            seen_ids.add(item.platform_listing_id)
            async with session_scope() as sess:
                existing_row = (
                    await sess.execute(
                        select(CompetitorListing).where(
                            CompetitorListing.competitor_id == seller.id,
                            CompetitorListing.platform_listing_id == item.platform_listing_id,
                        )
                    )
                ).scalar_one_or_none()
                now = dt.datetime.now(tz=dt.timezone.utc)
                if existing_row is None:
                    await sess.execute(
                        CompetitorListing.__table__.insert().values(
                            competitor_id=seller.id,
                            platform_listing_id=item.platform_listing_id,
                            title=item.title,
                            price_usd=item.price_usd,
                            first_seen=now,
                            last_seen=now,
                        )
                    )
                    await _telegram_alert(
                        f"🆕 competitor new: {seller.platform}/{seller.seller_handle}\n{item.title}\n${item.price_usd or '?'} · {item.url}"
                    )
                else:
                    if (
                        existing_row.price_usd
                        and item.price_usd
                        and item.price_usd < existing_row.price_usd * Decimal("0.90")
                    ):
                        await _telegram_alert(
                            f"🔻 competitor price drop: {existing_row.title}\n${existing_row.price_usd} → ${item.price_usd}\n{item.url}"
                        )
                    await sess.execute(
                        update(CompetitorListing)
                        .where(CompetitorListing.id == existing_row.id)
                        .values(price_usd=item.price_usd, last_seen=now)
                    )

    async with session_scope() as sess:
        now = dt.datetime.now(tz=dt.timezone.utc)
        stale_cutoff = now - dt.timedelta(hours=settings.competitor_watch_interval_hours * 3)
        stale = (
            await sess.execute(
                select(CompetitorListing).where(
                    CompetitorListing.competitor_id == seller.id,
                    CompetitorListing.sold.is_(False),
                    CompetitorListing.last_seen < stale_cutoff,
                )
            )
        ).scalars().all()
        for s in stale:
            await sess.execute(
                update(CompetitorListing).where(CompetitorListing.id == s.id).values(sold=True)
            )
            await _telegram_alert(
                f"✅ competitor sold: {seller.platform}/{seller.seller_handle}\n{s.title} @ ${s.price_usd or '?'}"
            )
        await sess.execute(
            update(CompetitorSeller).where(CompetitorSeller.id == seller.id).values(last_scanned=now)
        )


async def _run_async() -> None:
    async with session_scope() as sess:
        sellers = (
            await sess.execute(
                select(CompetitorSeller).where(CompetitorSeller.monitored.is_(True))
            )
        ).scalars().all()
    for s in sellers:
        try:
            await _scan_seller(s)
        except Exception as exc:
            logger.exception("competitor seller scan {}: {}", s.seller_handle, exc)
    logger.info("competitor_watch: scanned {} sellers", len(sellers))


def run(*_args, **_kwargs) -> None:
    asyncio.run(_run_async())
