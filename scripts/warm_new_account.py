"""Create a posting_account row in 'warming' status and kick off its 7-day cycle.

Prereqs:
  - You've already run scripts/login_<platform>.py --handle=<handle>
  - A session file exists under the platform's session dir.

Usage:
    python -m scripts.warm_new_account \\
        --platform depop --handle alice --email a@x.com --phone +15125550101
"""
from __future__ import annotations

import argparse
import asyncio
import datetime as dt
from pathlib import Path

from loguru import logger
from sqlalchemy.dialects.postgresql import insert as pg_insert

from src.config import settings
from src.db.models import PostingAccount
from src.db.session import session_scope
from src.playwright_pool.sessions import session_for
from src.utils.logging import configure_logging
from src.utils.proxy import available_slots


async def _run(platform: str, handle: str, email: str | None, phone: str | None, proxy_slot: str | None) -> None:
    store = session_for(platform, handle)
    if not store.exists():
        raise SystemExit(
            f"no session file for {platform}/{handle} at {store.path} — run login_{platform}.py first"
        )
    slots = available_slots()
    slot = proxy_slot or (slots[0] if slots else None)
    async with session_scope() as sess:
        await sess.execute(
            pg_insert(PostingAccount.__table__)
            .values(
                platform=platform,
                handle=handle,
                email=email,
                phone=phone,
                session_file=str(store.path),
                proxy_slot=slot,
                status="warming",
                warming_started_at=dt.datetime.now(tz=dt.timezone.utc),
                daily_limit=settings.max_listings_per_account_per_day,
            )
            .on_conflict_do_nothing(index_elements=["platform", "handle"])
        )
    logger.info("warming started: {}/{} session={} proxy_slot={}", platform, handle, store.path, slot)


def main() -> None:
    configure_logging()
    p = argparse.ArgumentParser()
    p.add_argument("--platform", required=True, choices=["depop", "grailed", "mercari"])
    p.add_argument("--handle", required=True)
    p.add_argument("--email")
    p.add_argument("--phone")
    p.add_argument("--proxy-slot")
    args = p.parse_args()
    asyncio.run(_run(args.platform, args.handle, args.email, args.phone, args.proxy_slot))


if __name__ == "__main__":
    main()
