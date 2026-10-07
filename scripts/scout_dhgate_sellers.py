"""Daily DHgate top-seller scout.

Walks a list of categories, scores sellers, upserts dhgate_sellers table.
score = round( rating × log1p(transaction_count) × response_rate )

Usage:
    python -m scripts.scout_dhgate_sellers --categories "corteiz,trapstar,essentials"
"""
from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import math

from loguru import logger
from sqlalchemy.dialects.postgresql import insert as pg_insert

from src.db.models import DhgateSeller
from src.db.session import session_scope
from src.scrapers.dhgate_seller import discover_sellers
from src.utils.logging import configure_logging


def _score(rating: float | None, tx: int | None, response_rate: float | None) -> int:
    r = float(rating or 0)
    t = math.log1p(float(tx or 0))
    rr = float(response_rate or 100) / 100.0
    return int(round(r * t * rr))


async def _run(categories: list[str], pages: int) -> int:
    seen: set[str] = set()
    wrote = 0
    async with session_scope() as sess:
        for cat in categories:
            sellers = await discover_sellers(cat, pages=pages)
            for s in sellers:
                if s["seller_id"] in seen:
                    continue
                seen.add(s["seller_id"])
                score = _score(s.get("rating"), s.get("transaction_count"), None)
                await sess.execute(
                    pg_insert(DhgateSeller.__table__)
                    .values(
                        seller_id=s["seller_id"],
                        store_name=s.get("store_name"),
                        store_url=s.get("store_url"),
                        rating=s.get("rating"),
                        transaction_count=s.get("transaction_count"),
                        score=score,
                        last_verified=dt.datetime.now(tz=dt.timezone.utc),
                    )
                    .on_conflict_do_update(
                        index_elements=["seller_id"],
                        set_={
                            "rating": s.get("rating"),
                            "transaction_count": s.get("transaction_count"),
                            "score": score,
                            "last_verified": dt.datetime.now(tz=dt.timezone.utc),
                        },
                    )
                )
                wrote += 1
    logger.info("scouted {} sellers across {} categories", wrote, len(categories))
    return wrote


def main() -> None:
    configure_logging()
    p = argparse.ArgumentParser()
    p.add_argument("--categories", required=True, help="comma-separated")
    p.add_argument("--pages", type=int, default=2)
    args = p.parse_args()
    cats = [c.strip() for c in args.categories.split(",") if c.strip()]
    asyncio.run(_run(cats, args.pages))


if __name__ == "__main__":
    main()
