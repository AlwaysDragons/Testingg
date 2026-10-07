"""Minimal smoke tests — Phase 0."""


def test_config_imports() -> None:
    import os

    os.environ.setdefault(
        "DATABASE_URL", "postgresql+asyncpg://ds:x@db:5432/dropship_mp"
    )
    os.environ.setdefault(
        "DATABASE_URL_SYNC", "postgresql+psycopg2://ds:x@db:5432/dropship_mp"
    )
    from src.config import get_settings

    s = get_settings()
    assert s.poll_sold_interval_minutes >= 1


def test_models_metadata() -> None:
    from src.db.models import Base

    assert "product_catalog" in Base.metadata.tables
    assert "sales" in Base.metadata.tables
    assert "supplier_orders" in Base.metadata.tables


def test_queue_registry() -> None:
    from src.queue import QUEUES

    assert "poll_sold" in QUEUES
    assert "fulfill_order" in QUEUES
    assert len(QUEUES) == 12
