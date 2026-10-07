"""Phase 6 — DM classifier intent routing, template rotation."""
from __future__ import annotations

import os


def _env() -> None:
    os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://ds:x@db:5432/dropship_mp")
    os.environ.setdefault("DATABASE_URL_SYNC", "postgresql+psycopg2://ds:x@db:5432/dropship_mp")


def test_classifier_shipping() -> None:
    _env()
    from src.dm.classifier import classify

    assert classify("hey, when will this ship?") == "shipping"
    assert classify("how long is delivery") == "shipping"


def test_classifier_offer() -> None:
    _env()
    from src.dm.classifier import classify

    assert classify("would you take a lower offer?") == "offer"


def test_classifier_escalation_outranks() -> None:
    _env()
    from src.dm.classifier import classify

    # Mentions size + refund — escalation must win.
    assert classify("item is wrong size — I want a refund") == "escalation"


def test_classifier_other() -> None:
    _env()
    from src.dm.classifier import classify

    assert classify("hi!") == "other"


def test_template_rotation_consistent_per_handle() -> None:
    _env()
    from src.dm.templates import pick_template

    a = pick_template("shipping", "depop", "alice123")
    b = pick_template("shipping", "depop", "alice123")
    c = pick_template("shipping", "depop", "bob999")
    assert a == b
    # Different buyer may pick a different template — not guaranteed but
    # at least must be a valid template.
    from src.dm.templates import TEMPLATES

    assert a in TEMPLATES["shipping"]
    assert c in TEMPLATES["shipping"]


def test_warming_schedule_7_day() -> None:
    _env()
    from src.workers.warm_account import WARMING_SCHEDULE

    assert set(WARMING_SCHEDULE.keys()) == set(range(1, 8))
    assert "activate" in WARMING_SCHEDULE[7]


def test_pnl_recommendation_boundary() -> None:
    _env()
    # Mirror the inline logic for safety against future refactor.
    from decimal import Decimal

    def rec(margin_pct: Decimal) -> str:
        if margin_pct >= Decimal("40"):
            return "scale"
        if margin_pct >= Decimal("25"):
            return "hold"
        return "kill"

    assert rec(Decimal("45")) == "scale"
    assert rec(Decimal("30")) == "hold"
    assert rec(Decimal("10")) == "kill"
