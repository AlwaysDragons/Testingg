"""Poll each active posting account's sold-items page and emit fulfillment jobs.

Idempotent on (platform, platform_sale_id). New sales get:
  - address fetched (DB write)
  - matched to our_listing via platform_listing_id
  - fulfill_order job enqueued, source picked by SKU stocking_mode
"""
from __future__ import annotations

import asyncio
from decimal import Decimal

from loguru import logger

from src.db.queries import (
    active_posting_accounts,
    create_supplier_order,
    find_our_listing_id,
    get_sku_stocking_mode,
    set_sale_address,
    upsert_sale,
)
from src.marketplaces.registry import get_marketplace, platform_fee
from src.queue import get_queue


async def _poll_account(account) -> int:
    """Returns count of new sales detected."""
    mp = get_marketplace(account.platform)
    try:
        events = await mp.poll_sold_items(account)
    except Exception as exc:
        logger.exception(
            "poll_sold failed {}/{}: {}", account.platform, account.handle, exc
        )
        return 0

    new_count = 0
    for ev in events:
        our_id, sku = (
            await find_our_listing_id(ev.platform, ev.platform_listing_id)
            if ev.platform_listing_id
            else (None, None)
        )
        fee = (
            Decimal(str(platform_fee(ev.platform, float(ev.sale_price_usd))))
            if ev.sale_price_usd is not None
            else None
        )
        sale_id, created = await upsert_sale(
            platform=ev.platform,
            platform_sale_id=ev.platform_sale_id,
            our_listing_id=our_id,
            buyer_handle=ev.buyer_handle,
            buyer_address=None,
            sale_price_usd=ev.sale_price_usd,
            platform_fee_usd=fee,
            sold_at=ev.sold_at,
        )
        if not created:
            continue
        new_count += 1

        try:
            addr = await mp.fetch_buyer_address(account, ev.platform_sale_id)
            if addr:
                await set_sale_address(sale_id, addr)
        except Exception as exc:
            logger.warning("buyer address fetch failed sale={}: {}", sale_id, exc)

        mode = await get_sku_stocking_mode(sku) if sku else None
        source = "reshipper" if mode == "prestocked" else "router"
        order_id = await create_supplier_order(sale_id=sale_id, sku=sku, source=source)
        get_queue("fulfill_order").enqueue(
            "src.workers.fulfill_order.run", order_id, job_timeout=600
        )
        logger.info(
            "new sale {}/{} sale_id={} order_id={} source={}",
            ev.platform,
            ev.platform_sale_id,
            sale_id,
            order_id,
            source,
        )
    return new_count


async def _run_async() -> None:
    accounts = await active_posting_accounts()
    if not accounts:
        logger.info("poll_sold: no active accounts")
        return
    counts = await asyncio.gather(
        *(_poll_account(a) for a in accounts), return_exceptions=True
    )
    total = sum(c for c in counts if isinstance(c, int))
    logger.info("poll_sold swept {} accounts, {} new sales", len(accounts), total)


def run(*_args, **_kwargs) -> None:
    asyncio.run(_run_async())
