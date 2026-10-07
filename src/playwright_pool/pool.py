"""Playwright browser pool.

Semaphore caps concurrent contexts at MAX_SIMULTANEOUS_BROWSERS to keep VPS
RAM bounded. Each `session()` lease returns a ready context with stealth
applied, correct proxy slot, and the account's storage_state preloaded.
On lease exit the storage_state is written back and the context closed.

One Playwright process + one Chromium browser are shared across the pool —
contexts are the per-account isolation boundary (own cookies, own fingerprint
patches, own proxy).
"""
from __future__ import annotations

import asyncio
import random
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass

from loguru import logger
from playwright.async_api import Browser, BrowserContext, Playwright, async_playwright

from src.config import settings
from src.playwright_pool.sessions import SessionStore, session_for
from src.playwright_pool.stealth import apply_stealth
from src.utils.proxy import build_proxy

USER_AGENTS = [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.4 Safari/605.1.15",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
]

VIEWPORTS = [
    {"width": 1440, "height": 900},
    {"width": 1536, "height": 864},
    {"width": 1680, "height": 1050},
]


@dataclass
class LeaseInfo:
    platform: str
    handle: str
    session: SessionStore
    headless: bool


class PlaywrightPool:
    """Lazy-initialized, process-global Playwright + Chromium pool."""

    def __init__(self):
        self._pw: Playwright | None = None
        self._browser: Browser | None = None
        self._sem = asyncio.Semaphore(settings.max_simultaneous_browsers)
        self._lock = asyncio.Lock()

    async def _ensure_browser(self) -> Browser:
        async with self._lock:
            if self._browser is not None and self._browser.is_connected():
                return self._browser
            if self._pw is None:
                self._pw = await async_playwright().start()
            # Chromium with the common hardening flags disabled — stealth handles the rest.
            self._browser = await self._pw.chromium.launch(
                headless=True,
                args=[
                    "--disable-blink-features=AutomationControlled",
                    "--disable-features=IsolateOrigins,site-per-process",
                    "--no-sandbox",
                    "--disable-dev-shm-usage",
                ],
            )
            return self._browser

    @asynccontextmanager
    async def session(
        self,
        platform: str,
        handle: str,
        *,
        proxy_slot: str | None = None,
        headless: bool = True,
        save_state: bool = True,
    ) -> AsyncIterator[BrowserContext]:
        """Lease a stealthed, authenticated context for (platform, handle)."""
        store = session_for(platform, handle)
        proxy = build_proxy(proxy_slot or f"{platform}:{handle}")

        async with self._sem:
            if headless:
                browser = await self._ensure_browser()
                owns_browser = False
            else:
                if self._pw is None:
                    self._pw = await async_playwright().start()
                browser = await self._pw.chromium.launch(headless=False)
                owns_browser = True

            storage_state = store.load()
            kwargs = {
                "user_agent": random.choice(USER_AGENTS),
                "viewport": random.choice(VIEWPORTS),
                "locale": "en-US",
                "timezone_id": "America/Chicago",
                "storage_state": storage_state,
            }
            if proxy is not None:
                kwargs["proxy"] = proxy.to_playwright()

            context = await browser.new_context(**{k: v for k, v in kwargs.items() if v})
            await apply_stealth(context)
            logger.debug(
                "lease {}:{} proxy={} saved_state={}",
                platform,
                handle,
                "yes" if proxy else "no",
                "yes" if storage_state else "no",
            )

            try:
                yield context
            finally:
                try:
                    if save_state:
                        new_state = await context.storage_state()
                        store.save(new_state)
                except Exception as exc:
                    logger.warning("session save failed {}:{} — {}", platform, handle, exc)
                finally:
                    await context.close()
                    if owns_browser:
                        await browser.close()

    async def close(self) -> None:
        async with self._lock:
            if self._browser is not None:
                await self._browser.close()
                self._browser = None
            if self._pw is not None:
                await self._pw.stop()
                self._pw = None


pool = PlaywrightPool()
