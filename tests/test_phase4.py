"""Phase 4 smoke — matcher scoring + opportunity scoring math."""
from __future__ import annotations

import os


def _env() -> None:
    os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://ds:x@db:5432/dropship_mp")
    os.environ.setdefault("DATABASE_URL_SYNC", "postgresql+psycopg2://ds:x@db:5432/dropship_mp")


def test_matcher_best_match() -> None:
    _env()
    from src.ranker.matcher import _CatalogRow, best_match

    catalog = [
        _CatalogRow(sku="SKU-1", corpus="corteiz alcatraz cargo pants"),
        _CatalogRow(sku="SKU-2", corpus="trapstar irongate tee"),
    ]
    hit = best_match("Corteiz Cargos — black L", catalog)
    assert hit is not None
    assert hit[0] == "SKU-1"

    hit2 = best_match("trapstar irongate tshirt tee", catalog)
    assert hit2 is not None and hit2[0] == "SKU-2"

    assert best_match("random pokemon card holder", catalog) is None


def test_matcher_empty_catalog() -> None:
    _env()
    from src.ranker.matcher import best_match

    assert best_match("whatever", []) is None


def test_scraped_listing_shape() -> None:
    _env()
    from decimal import Decimal

    from src.scrapers._base import ScrapedListing

    s = ScrapedListing(
        platform="depop",
        platform_listing_id="abc",
        title="t",
        price_usd=Decimal("40.00"),
        seller_handle=None,
        size=None,
        category=None,
        sold=False,
        posted_at=None,
        sold_at=None,
        url="https://example.com",
        image_url=None,
    )
    assert s.raw == {}
