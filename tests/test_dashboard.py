"""Dashboard — env parser/writer, HTML + api modules importable."""
from __future__ import annotations

import os
from pathlib import Path


def _env() -> None:
    os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://ds:x@db:5432/dropship_mp")
    os.environ.setdefault("DATABASE_URL_SYNC", "postgresql+psycopg2://ds:x@db:5432/dropship_mp")


def test_env_parse_and_write_roundtrip(tmp_path: Path) -> None:
    _env()
    from src.dashboard.app import _parse_env, _write_env

    p = tmp_path / ".env"
    p.write_text(
        "# comment line\n"
        "TELEGRAM_BOT_TOKEN=abc:def\n"
        "TELEGRAM_CHAT_ID=12345\n"
        "\n"
        "LOG_LEVEL=INFO\n"
    )
    parsed = _parse_env(p)
    assert parsed["TELEGRAM_BOT_TOKEN"] == "abc:def"
    assert parsed["TELEGRAM_CHAT_ID"] == "12345"

    _write_env(p, {"TELEGRAM_CHAT_ID": "99999", "NEW_KEY": "x"})
    after = _parse_env(p)
    assert after["TELEGRAM_BOT_TOKEN"] == "abc:def"  # preserved
    assert after["TELEGRAM_CHAT_ID"] == "99999"      # replaced in place
    assert after["NEW_KEY"] == "x"                   # appended
    # Comment preserved
    assert "# comment line" in p.read_text()


def test_editable_keys_list_has_telegram_and_proxy() -> None:
    _env()
    from src.dashboard.app import EDITABLE_KEYS, MASKED_KEYS

    assert "TELEGRAM_BOT_TOKEN" in EDITABLE_KEYS
    assert "PROXY_HOST" in EDITABLE_KEYS
    assert "TELEGRAM_BOT_TOKEN" in MASKED_KEYS
    assert "PROXY_HOST" not in MASKED_KEYS


def test_dashboard_app_has_routes() -> None:
    _env()
    from src.dashboard.app import app

    paths = {r.path for r in app.routes}
    for p in (
        "/",
        "/api/health",
        "/api/accounts",
        "/api/listings",
        "/api/sales",
        "/api/pnl",
        "/api/settings",
        "/api/logs/stream",
        "/api/action/post",
        "/api/action/dispute",
    ):
        assert p in paths, f"missing route {p}"


def test_index_html_exists() -> None:
    _env()
    from src.dashboard import app as mod

    assert mod.INDEX_HTML.exists()
    html = mod.INDEX_HTML.read_text()
    assert "<title>dropship-mp</title>" in html
    assert "tab-settings" in html
    assert "tab-logs" in html
