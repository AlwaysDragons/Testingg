"""Scrape all three marketplaces for active + sold listings matching our catalog.

Builds a fresh batch into market_listings, matches titles to SKUs via rapidfuzz,
runs the ranker, writes opportunities. Idempotent on (platform, platform_listing_id).
"""
from __future__ import annotations

import asyncio
import datetime as dt

from loguru import logger
from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert

from src.db.models import MarketListing, ProductCatalog, ScrapeRun
from src.db.session import session_scope
from src.ranker.matcher import match_unassigned
from src.ranker.opportunity import score_all_skus
from src.scrapers import depop as sd
from src.scrapers import grailed as sg
from src.scrapers import mercari as sm


async def _queries() -> list[str]:
    async with session_scope() as sess:
        rows = (await sess.execute(select(ProductCatalog.display_name).distinct())).all()
    base = [r[0] for r in rows if r[0]]
    return base or ["streetwear tee", "cargo pants", "hoodie"]


async def _persist_batch(batch) -> int:
    if not batch:
        return 0
    async with session_scope() as sess:
        wrote = 0
        for item in batch:
            stmt = (
                pg_insert(MarketListing.__table__)
                .values(
                    platform=item.platform,
                    platform_listing_id=item.platform_listing_id,
                    title=item.title,
                    price_usd=item.price_usd,
                    seller_handle=item.seller_handle,
                    size=item.size,
                    category=item.category,
                    sold=item.sold,
                    posted_at=item.posted_at,
                    sold_at=item.sold_at,
                    url=item.url,
                    image_url=item.image_url,
                )
                .on_conflict_do_update(
                    constraint="uq_market_listing_platform_id",
                    set_={
                        "price_usd": item.price_usd,
                        "sold": item.sold,
                        "sold_at": item.sold_at,
                    },
                )
            )
            await sess.execute(stmt)
            wrote += 1
        return wrote


async def _record_run(platform: str, query: str, found: int, errors: int, duration: int) -> None:
    async with session_scope() as sess:
        await sess.execute(
            ScrapeRun.__table__.insert().values(
                platform=platform,
                query=query,
                listings_found=found,
                errors=errors,
                duration_sec=duration,
            )
        )


async def _run_async() -> None:
    queries = await _queries()
    total = 0
    for query in queries:
        for platform, mod in (("depop", sd), ("grailed", sg), ("mercari", sm)):
            started = dt.datetime.utcnow()
            errors = 0
            found = 0
            try:
                batch = await mod.scrape_search(query, pages=2, sold=False)
                batch += await mod.scrape_search(query, pages=1, sold=True)
                found = await _persist_batch(batch)
                total += found
            except Exception as exc:
                logger.exception("scrape {}/{} failed: {}", platform, query, exc)
                errors = 1
            duration = int((dt.datetime.utcnow() - started).total_seconds())
            await _record_run(platform, query, found, errors, duration)
    logger.info("scrape pass complete: {} rows across {} queries", total, len(queries))

    matched = await match_unassigned()
    scored = await score_all_skus()
    logger.info("post-scrape: matched={} scored={}", matched, scored)


def run(*_args, **_kwargs) -> None:
    asyncio.run(_run_async())
