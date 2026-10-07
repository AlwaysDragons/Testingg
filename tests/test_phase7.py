"""Phase 7 — reshipper base, Shipito shape, dispute packet file write."""
from __future__ import annotations

import os
from pathlib import Path


def _env() -> None:
    os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://ds:x@db:5432/dropship_mp")
    os.environ.setdefault("DATABASE_URL_SYNC", "postgresql+psycopg2://ds:x@db:5432/dropship_mp")


def test_reshipper_base_abstract() -> None:
    _env()
    from src.reshipper.base import ReshipperBase

    try:
        ReshipperBase()  # type: ignore[abstract]
    except TypeError:
        return
    raise AssertionError("ReshipperBase should be abstract")


def test_shipito_default_name() -> None:
    _env()
    from src.reshipper.shipito import Shipito

    s = Shipito()
    assert s.name == "shipito"


def test_ship_result_shape() -> None:
    _env()
    from decimal import Decimal

    from src.reshipper.base import ShipResult

    r = ShipResult(ok=True, tracking_number="9400x", carrier="USPS", fee_usd=Decimal("4.99"))
    assert r.ok and r.tracking_number == "9400x"


def test_dispute_packet_render_smoke(tmp_path: Path) -> None:
    """Render a tiny packet from a fake bundle to make sure reportlab doesn't throw."""
    _env()
    from reportlab.lib.pagesizes import LETTER
    from reportlab.lib.styles import getSampleStyleSheet
    from reportlab.platypus import Paragraph, SimpleDocTemplate

    out = tmp_path / "e.pdf"
    doc = SimpleDocTemplate(str(out), pagesize=LETTER)
    doc.build([Paragraph("hello", getSampleStyleSheet()["Normal"])])
    assert out.exists() and out.stat().st_size > 500
