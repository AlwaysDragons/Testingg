"""Phase 2 smoke — supplier ABC conformance, router driver registry."""
from __future__ import annotations

import os


def _env() -> None:
    os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://ds:x@db:5432/dropship_mp")
    os.environ.setdefault("DATABASE_URL_SYNC", "postgresql+psycopg2://ds:x@db:5432/dropship_mp")


def test_dropship_notes_rotation() -> None:
    _env()
    from src.suppliers.base import DROPSHIP_NOTES

    assert len(DROPSHIP_NOTES) >= 3
    for n in DROPSHIP_NOTES:
        assert "invoice" in n.lower() or "neutral" in n.lower() or "plain" in n.lower()


def test_router_driver_registry() -> None:
    _env()
    from src.suppliers.base import SupplierBase
    from src.suppliers.router import get_driver

    for name in ("dhgate", "hoobuy", "kakobuy"):
        d = get_driver(name)
        assert isinstance(d, SupplierBase)
        assert d.name == name


def test_router_unknown_source() -> None:
    _env()
    from src.suppliers.router import get_driver

    try:
        get_driver("ebay")
    except ValueError:
        return
    raise AssertionError("unknown source should raise ValueError")


def test_variant_defaults() -> None:
    _env()
    from src.suppliers.base import Variant

    v = Variant()
    assert v.qty == 1
    assert v.color is None
    assert v.size is None


def test_buyer_address_shape() -> None:
    _env()
    from src.suppliers.base import BuyerAddress

    a = BuyerAddress(
        recipient="Jane Doe",
        line1="123 Main St",
        line2=None,
        city="Austin",
        state="TX",
        postal_code="78701",
    )
    assert a.country == "US"
    assert a.phone is None
