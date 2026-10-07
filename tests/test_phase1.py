"""Phase 1 smoke tests — pool structure, session store, proxy builder."""
from __future__ import annotations

import json
import os
from pathlib import Path


def _set_env() -> None:
    os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://ds:x@db:5432/dropship_mp")
    os.environ.setdefault("DATABASE_URL_SYNC", "postgresql+psycopg2://ds:x@db:5432/dropship_mp")


def test_proxy_builder_disabled_when_no_host() -> None:
    _set_env()
    os.environ["PROXY_HOST"] = ""
    os.environ["PROXY_USER"] = ""
    from src.config import get_settings
    from src.utils import proxy as proxy_mod

    get_settings.cache_clear()  # type: ignore[attr-defined]
    proxy_mod.settings = get_settings()
    assert proxy_mod.build_proxy("depop:alice") is None


def test_proxy_builder_brightdata_sticky_session() -> None:
    _set_env()
    os.environ["PROXY_HOST"] = "brd.superproxy.io"
    os.environ["PROXY_PORT"] = "22225"
    os.environ["PROXY_USER"] = "brd-customer-x"
    os.environ["PROXY_PASS"] = "pw"
    os.environ["PROXY_PROVIDER"] = "brightdata"

    from src.config import get_settings
    from src.utils import proxy as proxy_mod

    get_settings.cache_clear()  # type: ignore[attr-defined]
    proxy_mod.settings = get_settings()

    a = proxy_mod.build_proxy("depop:alice")
    b = proxy_mod.build_proxy("depop:alice")
    c = proxy_mod.build_proxy("depop:bob")
    assert a is not None and b is not None and c is not None
    assert a.username == b.username, "same slot must map to same session id"
    assert a.username != c.username, "different slots must map to different session ids"
    assert "session-" in a.username


def test_session_store_roundtrip(tmp_path: Path) -> None:
    _set_env()
    from src.playwright_pool.sessions import SessionStore

    s = SessionStore(tmp_path / "sub" / "alice.json")
    assert not s.exists()
    payload = {"cookies": [{"name": "sid", "value": "abc"}], "origins": []}
    s.save(payload)
    assert s.exists()
    loaded = s.load()
    assert loaded == payload


def test_session_for_resolves_platforms(tmp_path: Path) -> None:
    _set_env()
    os.environ["DEPOP_SESSION_DIR"] = str(tmp_path / "depop")
    os.environ["DHGATE_SESSION_FILE"] = str(tmp_path / "dhgate.json")

    from src.config import get_settings
    from src.playwright_pool import sessions

    get_settings.cache_clear()  # type: ignore[attr-defined]
    sessions.settings = get_settings()

    depop_store = sessions.session_for("depop", "alice")
    dh_store = sessions.session_for("dhgate", "dhgate")
    assert depop_store.path.name == "alice.json"
    assert dh_store.path.name == "dhgate.json"

    try:
        sessions.session_for("etsy", "x")
    except ValueError:
        pass
    else:
        raise AssertionError("unknown platform should have raised")


def test_login_scripts_present() -> None:
    for plat in ("depop", "grailed", "mercari", "dhgate", "hoobuy"):
        p = Path("scripts") / f"login_{plat}.py"
        assert p.exists(), f"missing {p}"
        text = p.read_text()
        assert f'cli("{plat}")' in text
    # ensure platform URLs are populated
    from scripts._login_common import PLATFORMS

    for plat in ("depop", "grailed", "mercari", "dhgate", "hoobuy"):
        assert PLATFORMS[plat].startswith("https://")


def test_pool_module_shape() -> None:
    _set_env()
    from src.playwright_pool import pool as pool_mod

    assert hasattr(pool_mod, "pool")
    assert hasattr(pool_mod.pool, "session")
