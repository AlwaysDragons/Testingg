"""Read new DMs for each active account, classify, auto-respond or flag.

Escalation + 'other' → set thread needs_human_review, Telegram alert.
Known intents → send a rotated template, record outgoing message.
"""
from __future__ import annotations

import asyncio
import datetime as dt

import httpx
from loguru import logger
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert

from src.config import settings
from src.db.models import DmMessage, DmThread, PostingAccount
from src.db.queries import active_posting_accounts
from src.db.session import session_scope
from src.dm.classifier import classify
from src.dm.templates import pick_template
from src.marketplaces.registry import get_marketplace


async def _telegram_alert(text: str) -> None:
    if not settings.telegram_bot_token or not settings.telegram_chat_id:
        return
    try:
        async with httpx.AsyncClient(timeout=10.0) as c:
            await c.post(
                f"https://api.telegram.org/bot{settings.telegram_bot_token}/sendMessage",
                json={"chat_id": settings.telegram_chat_id, "text": text[:3900]},
            )
    except Exception:
        pass


async def _get_or_create_thread(
    platform: str, posting_account_id: int, buyer_handle: str
) -> int:
    async with session_scope() as sess:
        row = (
            await sess.execute(
                select(DmThread.id).where(
                    DmThread.platform == platform,
                    DmThread.posting_account_id == posting_account_id,
                    DmThread.buyer_handle == buyer_handle,
                )
            )
        ).first()
        if row:
            return int(row[0])
        result = await sess.execute(
            DmThread.__table__.insert()
            .values(
                platform=platform,
                posting_account_id=posting_account_id,
                buyer_handle=buyer_handle,
                last_message_at=dt.datetime.now(tz=dt.timezone.utc),
            )
            .returning(DmThread.id)
        )
        return int(result.scalar_one())


async def _record_message(
    thread_id: int, direction: str, body: str, intent: str
) -> None:
    async with session_scope() as sess:
        await sess.execute(
            DmMessage.__table__.insert().values(
                thread_id=thread_id,
                direction=direction,
                body=body,
                classified_intent=intent,
            )
        )


async def _flag_thread(thread_id: int, reason: str) -> None:
    from sqlalchemy import update

    async with session_scope() as sess:
        await sess.execute(
            update(DmThread)
            .where(DmThread.id == thread_id)
            .values(needs_human_review=True, review_reason=reason)
        )


async def _poll_account(account: PostingAccount) -> int:
    mp = get_marketplace(account.platform)
    try:
        inbound = await mp.read_dms(account)
    except Exception as exc:
        logger.exception("read_dms {}: {}", account.handle, exc)
        return 0
    sent = 0
    for msg in inbound:
        intent = classify(msg.body)
        thread_id = await _get_or_create_thread(
            account.platform, account.id, msg.buyer_handle
        )
        await _record_message(thread_id, "in", msg.body, intent)

        if intent in ("escalation", "other"):
            await _flag_thread(thread_id, intent)
            await _telegram_alert(
                f"⚠️ {intent} DM on {account.platform}/{account.handle} from {msg.buyer_handle}:\n{msg.body[:500]}"
            )
            continue

        reply = pick_template(intent, account.platform, msg.buyer_handle)
        if reply is None:
            await _flag_thread(thread_id, f"no template for intent={intent}")
            continue
        ok = await mp.send_dm(account, msg.buyer_handle, reply)
        if ok:
            await _record_message(thread_id, "out", reply, intent)
            sent += 1
        else:
            await _flag_thread(thread_id, "send_dm failed")
    return sent


async def _run_async() -> None:
    accounts = await active_posting_accounts()
    if not accounts:
        return
    counts = await asyncio.gather(*(_poll_account(a) for a in accounts), return_exceptions=True)
    total = sum(c for c in counts if isinstance(c, int))
    logger.info("dm_responder: {} replies sent across {} accounts", total, len(accounts))


def run(*_args, **_kwargs) -> None:
    asyncio.run(_run_async())
