"""Phase 8 — DHgate scout scoring + WhatsApp manifest shape."""
from __future__ import annotations

import os


def _env() -> None:
    os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://ds:x@db:5432/dropship_mp")
    os.environ.setdefault("DATABASE_URL_SYNC", "postgresql+psycopg2://ds:x@db:5432/dropship_mp")


def test_scout_score_monotonic() -> None:
    _env()
    from scripts.scout_dhgate_sellers import _score

    s_bad = _score(3.5, 10, 50)
    s_good = _score(4.9, 50000, 95)
    assert s_good > s_bad


def test_scout_score_handles_none() -> None:
    _env()
    from scripts.scout_dhgate_sellers import _score

    assert _score(None, None, None) == 0


def test_whatsapp_manifest_contains_fields() -> None:
    _env()
    from src.suppliers.whatsapp import compose_manifest

    rows = [
        {
            "product_url": "https://dhgate.com/product/x",
            "qty": 2,
            "color": "Black",
            "size": "L",
            "ship_to": "US WH #4",
            "expected_price_usd": 12.5,
        },
        {
            "product_url": "https://dhgate.com/product/y",
            "qty": 1,
            "color": "Red",
            "size": "M",
            "ship_to": "US WH #4",
            "expected_price_usd": 15.0,
        },
    ]
    m = compose_manifest("Lucky Garment Store", rows)
    assert "Lucky Garment Store" in m
    assert "https://dhgate.com/product/x" in m
    assert "Expected total: $40.00" in m


def test_whatsapp_sender_dry_run_when_unconfigured() -> None:
    _env()
    from src.suppliers.whatsapp import WhatsAppSender

    os.environ.pop("TWILIO_ACCOUNT_SID", None)
    os.environ.pop("TWILIO_AUTH_TOKEN", None)
    os.environ.pop("TWILIO_WHATSAPP_FROM", None)
    s = WhatsAppSender()
    assert s.configured() is False


def test_suspend_markers_present() -> None:
    _env()
    from src.workers.health_check import SUSPEND_MARKERS

    for plat in ("depop", "grailed", "mercari"):
        assert plat in SUSPEND_MARKERS
        assert len(SUSPEND_MARKERS[plat]) >= 1
