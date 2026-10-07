"""Ask delivered buyers for a review once, after REVIEW_SOLICIT_DELAY_DAYS."""
from __future__ import annotations

import asyncio
import datetime as dt
import hashlib
import random

from loguru import logger
from sqlalchemy import select, update

from src.config import settings
from src.db.models import OurListing, PostingAccount, Sale, SupplierOrder
from src.db.session import session_scope
from src.marketplaces.registry import get_marketplace

ASKS = [
    "Hey! Hope the order arrived good. If you have a sec, a review would mean a lot — helps the shop a ton 🙏",
    "Hi! Just checking in — hope everything landed okay. Would love a quick review if you have a moment, big help!",
    "Hey, hope you're happy with it! If you can spare 30 seconds for a review it'd really help the shop out — thanks!",
]


async def _due_sales(cutoff: dt.datetime):
    async with session_scope() as sess:
        rows = (
            await sess.execute(
                select(Sale, SupplierOrder, OurListing, PostingAccount)
                .join(SupplierOrder, SupplierOrder.sale_id == Sale.id)
                .join(OurListing, OurListing.id == Sale.our_listing_id)
                .join(PostingAccount, PostingAccount.id == OurListing.posting_account_id)
                .where(
                    SupplierOrder.delivered_at.is_not(None),
                    SupplierOrder.delivered_at <= cutoff,
                    Sale.review_requested_at.is_(None),
                    Sale.review_received.is_(False),
                )
            )
        ).all()
    return rows


async def _run_async() -> int:
    cutoff = dt.datetime.now(tz=dt.timezone.utc) - dt.timedelta(
        days=settings.review_solicit_delay_days
    )
    rows = await _due_sales(cutoff)
    if not rows:
        return 0
    sent = 0
    for sale, _order, _listing, account in rows:
        if not sale.buyer_handle:
            continue
        mp = get_marketplace(account.platform)
        seed = int.from_bytes(
            hashlib.sha1(f"{sale.id}:{sale.buyer_handle}".encode()).digest()[:8], "big"
        )
        body = random.Random(seed).choice(ASKS)
        try:
            ok = await mp.send_dm(account, sale.buyer_handle, body)
            if ok:
                async with session_scope() as sess:
                    await sess.execute(
                        update(Sale)
                        .where(Sale.id == sale.id)
                        .values(review_requested_at=dt.datetime.now(tz=dt.timezone.utc))
                    )
                sent += 1
        except Exception as exc:
            logger.exception("review solicit failed sale={}: {}", sale.id, exc)
    logger.info("review solicit: {} / {} sent", sent, len(rows))
    return sent


def run(*_args, **_kwargs) -> None:
    asyncio.run(_run_async())
