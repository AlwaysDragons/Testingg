"""Proxy slot assignment for Playwright contexts.

Each posting / supplier account is pinned to a `proxy_slot` string. Pinning
keeps the same residential/ISP exit IP sticky per account across sessions,
which marketplace anti-fraud models score more trust against than rotating
exits for the same login.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass

from src.config import settings


@dataclass(frozen=True)
class ProxyConfig:
    server: str
    username: str
    password: str

    def to_playwright(self) -> dict[str, str]:
        return {
            "server": self.server,
            "username": self.username,
            "password": self.password,
        }


def _slot_hash(slot: str) -> int:
    return int(hashlib.sha1(slot.encode()).hexdigest(), 16)


def _bright_data_session_id(slot: str) -> str:
    # BrightData "session-<id>" param sticks the exit IP for that slot.
    return f"session-{_slot_hash(slot) % 10**9}"


def build_proxy(slot: str | None) -> ProxyConfig | None:
    """Resolve a slot label to a Playwright proxy config, or None if proxy disabled."""
    if not settings.proxy_host or not settings.proxy_user:
        return None
    if slot is None:
        slot = "default"

    if settings.proxy_provider == "brightdata":
        username = f"{settings.proxy_user}-{_bright_data_session_id(slot)}"
    else:
        username = settings.proxy_user

    return ProxyConfig(
        server=f"http://{settings.proxy_host}:{settings.proxy_port}",
        username=username,
        password=settings.proxy_pass,
    )


def available_slots() -> list[str]:
    return [f"slot-{i}" for i in range(settings.proxy_slots)]
