"""Daily account health check.

For each active account, hit its own profile URL and read status. If
the login redirects to login page or we see a suspension banner,
flip status -> suspended and Telegram-alert for operator to launch a
replacement with scripts/warm_new_account.py.

Resets listings_today at midnight local tz (via scheduler cadence).
"""
from __future__ import annotations

import asyncio
import datetime as dt

import httpx
from loguru import logger
from sqlalchemy import update

from src.config import settings
from src.db.models import PostingAccount
from src.db.queries import active_posting_accounts
from src.db.session import session_scope
from src.playwright_pool import pool

SUSPEND_MARKERS = {
    "depop": ["your account has been suspended", "This account is temporarily unavailable"],
    "grailed": ["Your account has been", "account suspended"],
    "mercari": ["account on hold", "account has been suspended"],
}
PROFILE_URL = {
    "depop": "https://www.depop.com/{handle}/",
    "grailed": "https://www.grailed.com/{handle}",
    "mercari": "https://www.mercari.com/u/{handle}/",
}


async def _alert(text: str) -> None:
    if not settings.telegram_bot_token or not settings.telegram_chat_id:
        return
    try:
        async with httpx.AsyncClient(timeout=10) as c:
            await c.post(
                f"https://api.telegram.org/bot{settings.telegram_bot_token}/sendMessage",
                json={"chat_id": settings.telegram_chat_id, "text": text[:3900]},
            )
    except Exception:
        pass


async def _check(account: PostingAccount) -> bool:
    url = PROFILE_URL.get(account.platform, "").format(handle=account.handle)
    if not url:
        return True
    async with pool.session(
        account.platform, account.handle, proxy_slot=account.proxy_slot
    ) as ctx:
        page = await ctx.new_page()
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=30_000)
            body = (await page.content()).lower()
            for marker in SUSPEND_MARKERS.get(account.platform, []):
                if marker.lower() in body:
                    return False
            return True
        except Exception as exc:
            logger.warning("health check error {}/{}: {}", account.platform, account.handle, exc)
            return True
        finally:
            await page.close()


async def _reset_daily_counters() -> None:
    async with session_scope() as sess:
        await sess.execute(update(PostingAccount).values(listings_today=0))


async def _run_async() -> None:
    accounts = await active_posting_accounts()
    for a in accounts:
        ok = await _check(a)
        if not ok:
            async with session_scope() as sess:
                await sess.execute(
                    update(PostingAccount)
                    .where(PostingAccount.id == a.id)
                    .values(status="suspended")
                )
            await _alert(
                f"🚨 account suspended: {a.platform}/{a.handle}\n"
                f"Launch replacement:\n"
                f"  python -m scripts.login_{a.platform} --handle <new>\n"
                f"  python -m scripts.warm_new_account --platform {a.platform} --handle <new>"
            )
    await _reset_daily_counters()
    logger.info("health_check: {} accounts scanned", len(accounts))


def run(*_args, **_kwargs) -> None:
    asyncio.run(_run_async())
