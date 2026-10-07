"""Fuzzy match scraped listings against product_catalog SKUs.

RapidFuzz WRatio across (display_name + variant_group) handles minor
title noise, misspellings, and extra adjectives. A match requires
score >= THRESHOLD or the listing stays unassigned.
"""
from __future__ import annotations

from dataclasses import dataclass

from loguru import logger
from rapidfuzz import process, fuzz
from sqlalchemy import select, update

from src.db.models import MarketListing, ProductCatalog
from src.db.session import session_scope

THRESHOLD = 72


@dataclass
class _CatalogRow:
    sku: str
    corpus: str


async def _load_catalog() -> list[_CatalogRow]:
    async with session_scope() as sess:
        rows = (
            await sess.execute(
                select(ProductCatalog.sku, ProductCatalog.display_name, ProductCatalog.variant_group)
            )
        ).all()
    return [
        _CatalogRow(sku=r[0], corpus=" ".join(x for x in (r[1], r[2] or "") if x).lower())
        for r in rows
    ]


def best_match(title: str, catalog: list[_CatalogRow]) -> tuple[str, int] | None:
    if not title or not catalog:
        return None
    hit = process.extractOne(
        title.lower(),
        [c.corpus for c in catalog],
        scorer=fuzz.WRatio,
        score_cutoff=THRESHOLD,
    )
    if not hit:
        return None
    _, score, idx = hit
    return catalog[idx].sku, int(score)


async def match_unassigned() -> int:
    catalog = await _load_catalog()
    if not catalog:
        return 0
    async with session_scope() as sess:
        rows = (
            await sess.execute(
                select(MarketListing.id, MarketListing.title).where(
                    MarketListing.matched_sku.is_(None)
                )
            )
        ).all()
    updated = 0
    async with session_scope() as sess:
        for ml_id, title in rows:
            m = best_match(title or "", catalog)
            if m is None:
                continue
            sku, _score = m
            await sess.execute(
                update(MarketListing).where(MarketListing.id == ml_id).values(matched_sku=sku)
            )
            updated += 1
    logger.info("fuzzy matcher: {} / {} listings matched", updated, len(rows))
    return updated
