"""Pick the next posting account on a platform respecting daily limits + cooldowns."""
from __future__ import annotations

import datetime as dt

from loguru import logger
from sqlalchemy import select, update

from src.db.models import PostingAccount
from src.db.session import session_scope


async def pick_account(platform: str) -> PostingAccount | None:
    now = dt.datetime.now(tz=dt.timezone.utc)
    async with session_scope() as sess:
        rows = (
            await sess.execute(
                select(PostingAccount).where(
                    PostingAccount.platform == platform,
                    PostingAccount.status == "active",
                )
            )
        ).scalars().all()

    eligible = [
        a for a in rows
        if (a.listings_today or 0) < (a.daily_limit or 5)
        and (a.cooldown_until is None or a.cooldown_until < now)
    ]
    if not eligible:
        logger.warning("rotation: no eligible accounts for {}", platform)
        return None
    eligible.sort(key=lambda a: (a.last_posted or dt.datetime.min.replace(tzinfo=dt.timezone.utc)))
    return eligible[0]


async def record_posted(account_id: int) -> None:
    async with session_scope() as sess:
        await sess.execute(
            update(PostingAccount)
            .where(PostingAccount.id == account_id)
            .values(
                last_posted=dt.datetime.now(tz=dt.timezone.utc),
                listings_today=PostingAccount.listings_today + 1,
            )
        )


def poster_for(platform: str):
    from src.posters.depop import DepopPoster
    from src.posters.grailed import GrailedPoster
    from src.posters.mercari import MercariPoster

    registry = {"depop": DepopPoster(), "grailed": GrailedPoster(), "mercari": MercariPoster()}
    if platform not in registry:
        raise ValueError(f"no poster for platform {platform}")
    return registry[platform]
