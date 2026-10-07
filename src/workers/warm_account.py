"""7-day account warm cycle.

Marketplace fraud models score new accounts on behavioural pattern. Immediate
listing from a fresh account hurts search ranking. One day = one bucket.
On day 7 we flip status warming -> active and the rotation picks it up.

Actions are intentionally bland — browse, favorite, follow, like, send a
'does this run tts?' message. We don't post anything that could get flagged
during warming.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import random

from loguru import logger
from sqlalchemy import select, update

from src.config import settings
from src.db.models import PostingAccount
from src.db.session import session_scope
from src.playwright_pool import pool

WARMING_SCHEDULE: dict[int, list[str]] = {
    1: ["browse_30min", "favorite_3", "follow_2"],
    2: ["browse_20min", "favorite_2", "search_random"],
    3: ["browse_30min", "favorite_4", "follow_3", "like_comments_2"],
    4: ["browse_20min", "message_a_seller_asking_size"],
    5: ["browse_30min", "favorite_5", "add_to_bag_then_abandon"],
    6: ["browse_20min", "complete_profile_bio", "upload_profile_pic"],
    7: ["browse_30min", "favorite_3", "activate"],
}

BROWSE_PATHS: dict[str, list[str]] = {
    "depop": ["/", "/explore/", "/category/menswear/", "/search/?q=cargos"],
    "grailed": ["/", "/categories/tops", "/categories/bottoms", "/shop?query=hoodie"],
    "mercari": ["/", "/category/clothing/", "/search/?keyword=denim"],
}


async def _browse(account: PostingAccount, minutes: int) -> None:
    paths = BROWSE_PATHS.get(account.platform, ["/"])
    end = dt.datetime.utcnow() + dt.timedelta(minutes=minutes)
    async with pool.session(account.platform, account.handle, proxy_slot=account.proxy_slot) as ctx:
        page = await ctx.new_page()
        try:
            base = f"https://www.{account.platform}.com"
            while dt.datetime.utcnow() < end:
                p = random.choice(paths)
                try:
                    await page.goto(base + p, wait_until="domcontentloaded", timeout=30_000)
                    for _ in range(random.randint(3, 8)):
                        await page.mouse.wheel(0, random.randint(300, 1200))
                        await page.wait_for_timeout(random.randint(1500, 4000))
                except Exception as exc:
                    logger.debug("warming browse hiccup: {}", exc)
                    break
        finally:
            await page.close()


async def _warm_account(account: PostingAccount, day: int) -> None:
    actions = WARMING_SCHEDULE.get(day, [])
    logger.info("warming {}/{} day={} actions={}", account.platform, account.handle, day, actions)
    for action in actions:
        if action.startswith("browse_"):
            minutes = int(action.split("_")[1].rstrip("min"))
            await _browse(account, minutes=min(minutes, 5))  # cap per-run for VPS budget
        elif action == "activate":
            async with session_scope() as sess:
                await sess.execute(
                    update(PostingAccount)
                    .where(PostingAccount.id == account.id)
                    .values(
                        status="active",
                        activated_at=dt.datetime.now(tz=dt.timezone.utc),
                    )
                )
            logger.info("account activated: {}/{}", account.platform, account.handle)
        else:
            logger.debug("skipping warm action placeholder: {}", action)


async def _run_daily_async() -> None:
    now = dt.datetime.now(tz=dt.timezone.utc)
    async with session_scope() as sess:
        rows = (
            await sess.execute(
                select(PostingAccount).where(PostingAccount.status == "warming")
            )
        ).scalars().all()
    for a in rows:
        if a.warming_started_at is None:
            continue
        day = (now.date() - a.warming_started_at.date()).days + 1
        if day < 1 or day > settings.warming_period_days:
            continue
        try:
            await _warm_account(a, day)
        except Exception as exc:
            logger.exception("warm failed {}/{}: {}", a.platform, a.handle, exc)


def run_daily(*_args, **_kwargs) -> None:
    asyncio.run(_run_daily_async())


def run(*_args, **_kwargs) -> None:
    run_daily()
