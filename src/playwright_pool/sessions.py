"""Session (storage_state) loading + saving for Playwright contexts.

Each account's cookies + localStorage are serialized to a JSON file on the
sessiondata volume. The pool reads it at launch, Playwright writes it back
on shutdown so refreshed CSRF tokens / long-lived auth cookies persist.
"""
from __future__ import annotations

import json
from pathlib import Path

from loguru import logger

from src.config import settings


class SessionStore:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def exists(self) -> bool:
        return self.path.exists() and self.path.stat().st_size > 0

    def load(self) -> dict | None:
        if not self.exists():
            return None
        try:
            return json.loads(self.path.read_text())
        except json.JSONDecodeError as exc:
            logger.warning("corrupt session file {}: {}", self.path, exc)
            return None

    def save(self, storage_state: dict) -> None:
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp.write_text(json.dumps(storage_state))
        tmp.replace(self.path)
        logger.debug("session saved -> {}", self.path)


def session_for(platform: str, handle: str) -> SessionStore:
    """Resolve a session file path for a (platform, handle) pair."""
    dir_map = {
        "depop": settings.depop_session_dir,
        "grailed": settings.grailed_session_dir,
        "mercari": settings.mercari_session_dir,
    }
    if platform in dir_map:
        return SessionStore(Path(dir_map[platform]) / f"{handle}.json")

    supplier_map = {
        "dhgate": settings.dhgate_session_file,
        "hoobuy": settings.hoobuy_session_file,
        "kakobuy": settings.kakobuy_session_file,
    }
    if platform in supplier_map:
        return SessionStore(supplier_map[platform])

    raise ValueError(f"unknown platform for session: {platform}")
