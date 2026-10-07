"""Shared interactive-login harness for all 5 target sites.

Flow:
  1. Launch Chromium headful (own browser, not pooled) with correct proxy + UA.
  2. Load any existing storage_state so the operator sees whether they're
     still logged in; if so one visit confirms, press Enter, done.
  3. Navigate to the site's login URL. Operator completes login (incl. captcha,
     SMS, email code) by hand in the open window.
  4. On Enter, serialize storage_state to the account's session file and exit.

Usage from host (where Chromium can draw):
    python -m scripts.login_depop --handle alice
"""
from __future__ import annotations

import argparse
import asyncio
import sys

from loguru import logger
from playwright.async_api import async_playwright

from src.playwright_pool.sessions import session_for
from src.playwright_pool.stealth import apply_stealth
from src.utils.proxy import build_proxy

PLATFORMS = {
    "depop": "https://www.depop.com/login/",
    "grailed": "https://www.grailed.com/users/sign_up",
    "mercari": "https://www.mercari.com/login/",
    "dhgate": "https://www.dhgate.com/login/signin.html",
    "hoobuy": "https://www.hoobuy.com/user/login",
}


async def run(platform: str, handle: str, proxy_slot: str | None) -> None:
    if platform not in PLATFORMS:
        raise SystemExit(f"unknown platform {platform!r}; one of {list(PLATFORMS)}")

    store = session_for(platform, handle)
    proxy = build_proxy(proxy_slot or f"{platform}:{handle}")

    async with async_playwright() as pw:
        launch_kwargs: dict = {"headless": False}
        if proxy is not None:
            launch_kwargs["proxy"] = proxy.to_playwright()
        browser = await pw.chromium.launch(**launch_kwargs)

        ctx_kwargs: dict = {
            "locale": "en-US",
            "timezone_id": "America/Chicago",
        }
        state = store.load()
        if state:
            ctx_kwargs["storage_state"] = state

        context = await browser.new_context(**ctx_kwargs)
        await apply_stealth(context)

        page = await context.new_page()
        await page.goto(PLATFORMS[platform], wait_until="domcontentloaded")
        logger.info(
            "{} opened for handle={}. complete login in the window, then press Enter here.",
            platform,
            handle,
        )

        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, sys.stdin.readline)

        new_state = await context.storage_state()
        store.save(new_state)
        logger.info("session saved: {}", store.path)

        await context.close()
        await browser.close()


def cli(platform: str) -> None:
    parser = argparse.ArgumentParser(description=f"interactive login for {platform}")
    parser.add_argument(
        "--handle",
        required=platform in ("depop", "grailed", "mercari"),
        default=platform if platform in ("dhgate", "hoobuy", "kakobuy") else None,
        help="account label (file name under the platform's session dir)",
    )
    parser.add_argument(
        "--proxy-slot",
        default=None,
        help="optional proxy slot; defaults to <platform>:<handle>",
    )
    args = parser.parse_args()
    asyncio.run(run(platform, args.handle, args.proxy_slot))
