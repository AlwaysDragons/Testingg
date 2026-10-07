"""Phase 3 smoke — marketplace registry, address parsing, platform fees."""
from __future__ import annotations

import os


def _env() -> None:
    os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://ds:x@db:5432/dropship_mp")
    os.environ.setdefault("DATABASE_URL_SYNC", "postgresql+psycopg2://ds:x@db:5432/dropship_mp")


def test_marketplace_registry() -> None:
    _env()
    from src.marketplaces.base import MarketplaceBase
    from src.marketplaces.registry import get_marketplace

    for name in ("depop", "grailed", "mercari"):
        m = get_marketplace(name)
        assert isinstance(m, MarketplaceBase)
        assert m.name == name


def test_marketplace_registry_unknown() -> None:
    _env()
    from src.marketplaces.registry import get_marketplace

    try:
        get_marketplace("etsy")
    except ValueError:
        return
    raise AssertionError("unknown marketplace should raise")


def test_platform_fee_math() -> None:
    _env()
    from src.marketplaces.registry import platform_fee

    assert platform_fee("depop", 50.0) == 5.00
    assert platform_fee("grailed", 100.0) == 9.00
    assert platform_fee("mercari", 25.0) == 2.50


def test_address_parse_basic() -> None:
    _env()
    from src.marketplaces._common import address_lines_to_dict

    lines = ["Jane Doe", "123 Main St", "Austin, TX 78701", "USA"]
    d = address_lines_to_dict(lines)
    assert d["recipient"] == "Jane Doe"
    assert d["line1"] == "123 Main St"
    assert d["city"] == "Austin"
    assert d["state"] == "TX"
    assert d["postal_code"] == "78701"
    assert d["country"] == "US"


def test_address_parse_with_apt() -> None:
    _env()
    from src.marketplaces._common import address_lines_to_dict

    lines = ["John Smith", "742 Evergreen Ter", "Apt 4B", "Springfield, OR 97477"]
    d = address_lines_to_dict(lines)
    assert d["city"] == "Springfield"
    assert d["state"] == "OR"
    assert d["postal_code"] == "97477"
    assert d["line2"] == "Apt 4B"


def test_price_parse() -> None:
    _env()
    from decimal import Decimal

    from src.marketplaces._common import parse_price

    assert parse_price("$42.00") == Decimal("42.00")
    assert parse_price("USD 1,234.56".replace(",", "")) == Decimal("1234.56")
    assert parse_price("sold") is None


def test_sale_event_shape() -> None:
    _env()
    import datetime as dt

    from src.marketplaces.base import SaleEvent

    ev = SaleEvent(
        platform="depop",
        platform_sale_id="abc",
        platform_listing_id="xyz",
        buyer_handle="alice",
        sale_price_usd=None,
        sold_at=dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc),
    )
    assert ev.raw == {}
