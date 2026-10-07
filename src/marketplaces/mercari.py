from __future__ import annotations

import asyncio
import random
from typing import Any

from loguru import logger

from src.db.models import PostingAccount
from src.marketplaces._common import address_lines_to_dict, parse_price, utcnow
from src.marketplaces.base import DMMessage, MarketplaceBase, SaleEvent
from src.marketplaces.selectors import mercari as sel
from src.playwright_pool import pool


class Mercari(MarketplaceBase):
    name = "mercari"

    async def _check_bot_wall(self, page) -> None:
        for marker in sel.BOT_MARKERS:
            if await page.locator(marker).count():
                raise RuntimeError(f"mercari bot-check: {marker}")

    async def poll_sold_items(self, account: PostingAccount) -> list[SaleEvent]:
        out: list[SaleEvent] = []
        async with pool.session(
            account.platform, account.handle, proxy_slot=account.proxy_slot
        ) as ctx:
            page = await ctx.new_page()
            await page.goto(sel.SOLD_URL, wait_until="domcontentloaded", timeout=45_000)
            await self._check_bot_wall(page)
            cards = page.locator(sel.SOLD_CARD)
            for i in range(await cards.count()):
                c = cards.nth(i)
                sale_id = await c.get_attribute(sel.SOLD_SALE_ID_ATTR) or ""
                listing_id = await c.get_attribute(sel.SOLD_LISTING_ID_ATTR) or ""
                buyer_el = c.locator(sel.SOLD_BUYER).first
                buyer = (
                    (await buyer_el.inner_text()).strip().lstrip("@")
                    if await buyer_el.count()
                    else None
                )
                price_el = c.locator(sel.SOLD_PRICE).first
                price_txt = await price_el.inner_text() if await price_el.count() else ""
                if not sale_id:
                    continue
                out.append(
                    SaleEvent(
                        platform="mercari",
                        platform_sale_id=sale_id,
                        platform_listing_id=listing_id or None,
                        buyer_handle=buyer,
                        sale_price_usd=parse_price(price_txt),
                        sold_at=utcnow(),
                    )
                )
            logger.info("mercari/{}: {} sold rows", account.handle, len(out))
            await page.close()
        return out

    async def fetch_buyer_address(
        self, account: PostingAccount, sale_id: str
    ) -> dict[str, Any] | None:
        async with pool.session(
            account.platform, account.handle, proxy_slot=account.proxy_slot
        ) as ctx:
            page = await ctx.new_page()
            try:
                await page.goto(
                    sel.SALE_DETAIL_URL.format(sale_id=sale_id),
                    wait_until="domcontentloaded",
                    timeout=30_000,
                )
                await self._check_bot_wall(page)
                lines_loc = page.locator(sel.ADDRESS_LINES)
                lines = [
                    (await lines_loc.nth(i).inner_text()).strip()
                    for i in range(await lines_loc.count())
                ]
                return address_lines_to_dict(lines) if lines else None
            finally:
                await page.close()

    async def push_tracking(
        self, account: PostingAccount, sale_id: str, tracking: str, carrier: str
    ) -> bool:
        async with pool.session(
            account.platform, account.handle, proxy_slot=account.proxy_slot
        ) as ctx:
            page = await ctx.new_page()
            try:
                await page.goto(
                    sel.SALE_DETAIL_URL.format(sale_id=sale_id),
                    wait_until="domcontentloaded",
                    timeout=30_000,
                )
                await self._check_bot_wall(page)
                await page.locator(sel.TRACKING_INPUT).first.fill(tracking)
                carrier_el = page.locator(sel.CARRIER_SELECT).first
                if await carrier_el.count():
                    try:
                        await carrier_el.select_option(carrier)
                    except Exception:
                        await carrier_el.select_option(label=carrier)
                await page.locator(sel.TRACKING_SAVE).first.click()
                await asyncio.sleep(random.uniform(0.5, 1.0))
                return True
            except Exception as exc:
                logger.exception("mercari push_tracking: {}", exc)
                return False
            finally:
                await page.close()

    async def send_dm(
        self, account: PostingAccount, buyer_handle: str, body: str
    ) -> bool:
        async with pool.session(
            account.platform, account.handle, proxy_slot=account.proxy_slot
        ) as ctx:
            page = await ctx.new_page()
            try:
                await page.goto(sel.DM_INBOX_URL, wait_until="domcontentloaded", timeout=30_000)
                await self._check_bot_wall(page)
                threads = page.locator(sel.DM_THREAD_CARD)
                for i in range(await threads.count()):
                    t = threads.nth(i)
                    name = t.locator(sel.DM_BUYER).first
                    if await name.count() and buyer_handle.lower() in (
                        await name.inner_text()
                    ).lower():
                        await t.click()
                        await page.locator(sel.DM_INPUT).first.fill(body)
                        await page.locator(sel.DM_SEND).first.click()
                        return True
                return False
            except Exception as exc:
                logger.exception("mercari send_dm: {}", exc)
                return False
            finally:
                await page.close()

    async def read_dms(self, account: PostingAccount) -> list[DMMessage]:
        out: list[DMMessage] = []
        async with pool.session(
            account.platform, account.handle, proxy_slot=account.proxy_slot
        ) as ctx:
            page = await ctx.new_page()
            try:
                await page.goto(sel.DM_INBOX_URL, wait_until="domcontentloaded", timeout=30_000)
                await self._check_bot_wall(page)
                threads = page.locator(sel.DM_THREAD_CARD)
                for i in range(await threads.count()):
                    t = threads.nth(i)
                    if not await t.locator(sel.DM_UNREAD).first.count():
                        continue
                    name_el = t.locator(sel.DM_BUYER).first
                    buyer = (
                        (await name_el.inner_text()).strip().lstrip("@")
                        if await name_el.count()
                        else "unknown"
                    )
                    await t.click()
                    msgs = page.locator(sel.DM_MESSAGES)
                    if await msgs.count():
                        body = (await msgs.nth(await msgs.count() - 1).inner_text()).strip()
                        if body:
                            out.append(
                                DMMessage(
                                    platform="mercari",
                                    buyer_handle=buyer,
                                    body=body,
                                    sent_at=utcnow(),
                                )
                            )
                return out
            finally:
                await page.close()

    async def update_listing_price(
        self, account: PostingAccount, listing_id: str, new_price: float
    ) -> bool:
        async with pool.session(
            account.platform, account.handle, proxy_slot=account.proxy_slot
        ) as ctx:
            page = await ctx.new_page()
            try:
                await page.goto(
                    sel.LISTING_EDIT_URL.format(listing_id=listing_id),
                    wait_until="domcontentloaded",
                    timeout=30_000,
                )
                await self._check_bot_wall(page)
                await page.locator(sel.LISTING_PRICE_INPUT).first.fill(f"{new_price:.2f}")
                await page.locator(sel.LISTING_SAVE).first.click()
                return True
            except Exception as exc:
                logger.exception("mercari reprice: {}", exc)
                return False
            finally:
                await page.close()
