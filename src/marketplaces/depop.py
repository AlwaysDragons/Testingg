from __future__ import annotations

import asyncio
import random
from typing import Any

from loguru import logger
from playwright.async_api import TimeoutError as PWTimeout

from src.db.models import PostingAccount
from src.marketplaces._common import address_lines_to_dict, parse_price, utcnow
from src.marketplaces.base import DMMessage, MarketplaceBase, SaleEvent
from src.marketplaces.selectors import depop as sel
from src.playwright_pool import pool


class Depop(MarketplaceBase):
    name = "depop"

    async def _check_bot_wall(self, page) -> None:
        for marker in sel.BOT_CHECK_MARKERS:
            if await page.locator(marker).count():
                raise RuntimeError(f"depop bot-check: {marker}")

    async def poll_sold_items(self, account: PostingAccount) -> list[SaleEvent]:
        out: list[SaleEvent] = []
        async with pool.session(
            account.platform, account.handle, proxy_slot=account.proxy_slot, headless=True
        ) as ctx:
            page = await ctx.new_page()
            await page.goto(
                sel.SOLD_ITEMS_URL.format(handle=account.handle),
                wait_until="domcontentloaded",
                timeout=45_000,
            )
            await self._check_bot_wall(page)
            cards = page.locator(sel.SOLD_ITEM_CARD)
            n = await cards.count()
            for i in range(n):
                card = cards.nth(i)
                sale_id = await card.get_attribute(sel.SOLD_ITEM_SALE_ID_ATTR) or ""
                link_el = card.locator(sel.SOLD_ITEM_LINK).first
                href = await link_el.get_attribute("href") if await link_el.count() else None
                price_el = card.locator(sel.SOLD_ITEM_PRICE).first
                price_txt = await price_el.inner_text() if await price_el.count() else ""
                listing_id = href.strip("/").split("/")[-1] if href else None
                if not sale_id and not listing_id:
                    continue
                out.append(
                    SaleEvent(
                        platform="depop",
                        platform_sale_id=sale_id or f"depop-{listing_id}-{account.handle}",
                        platform_listing_id=listing_id,
                        buyer_handle=None,
                        sale_price_usd=parse_price(price_txt),
                        sold_at=utcnow(),
                        raw={"card_index": i},
                    )
                )
            logger.info("depop/{}: {} sold item(s) scanned", account.handle, len(out))
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
                buyer = None
                buyer_el = page.locator(sel.SALE_BUYER_HANDLE).first
                if await buyer_el.count():
                    buyer = (await buyer_el.inner_text()).strip().lstrip("@")

                lines_loc = page.locator(sel.SALE_ADDRESS_LINES)
                lines = []
                for i in range(await lines_loc.count()):
                    lines.append((await lines_loc.nth(i).inner_text()).strip())
                if not lines:
                    return None
                addr = address_lines_to_dict(lines)
                addr["buyer_handle"] = buyer
                return addr
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
                await page.locator(sel.SALE_TRACKING_INPUT).first.fill(tracking)
                carrier_sel = page.locator(sel.SALE_CARRIER_SELECT).first
                if await carrier_sel.count():
                    try:
                        await carrier_sel.select_option(carrier)
                    except Exception:
                        await carrier_sel.select_option(label=carrier)
                await page.locator(sel.SALE_SAVE_TRACKING).first.click()
                await asyncio.sleep(random.uniform(0.6, 1.2))
                logger.info("depop tracking pushed: sale={} tracking={}", sale_id, tracking)
                return True
            except Exception as exc:
                logger.exception("depop push_tracking failed: {}", exc)
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
                found = False
                for i in range(await threads.count()):
                    t = threads.nth(i)
                    name = t.locator(sel.DM_THREAD_BUYER).first
                    if await name.count() and buyer_handle.lower() in (
                        await name.inner_text()
                    ).lower():
                        await t.click()
                        found = True
                        break
                if not found:
                    logger.warning("depop dm: no thread for {}", buyer_handle)
                    return False
                await page.locator(sel.DM_MESSAGE_INPUT).first.fill(body)
                await page.locator(sel.DM_SEND_BUTTON).first.click()
                return True
            except Exception as exc:
                logger.exception("depop send_dm failed: {}", exc)
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
                    unread = t.locator(sel.DM_UNREAD_INDICATOR).first
                    if not await unread.count():
                        continue
                    name_el = t.locator(sel.DM_THREAD_BUYER).first
                    buyer = (
                        (await name_el.inner_text()).strip().lstrip("@")
                        if await name_el.count()
                        else "unknown"
                    )
                    await t.click()
                    await asyncio.sleep(random.uniform(0.3, 0.7))
                    msgs = page.locator(sel.DM_MESSAGES_LIST)
                    if await msgs.count():
                        last = msgs.nth(await msgs.count() - 1)
                        try:
                            body = (await last.inner_text(timeout=1500)).strip()
                        except PWTimeout:
                            body = ""
                        if body:
                            out.append(
                                DMMessage(
                                    platform="depop",
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
                inp = page.locator(sel.LISTING_PRICE_INPUT).first
                await inp.fill(f"{new_price:.2f}")
                await page.locator(sel.LISTING_SAVE_BUTTON).first.click()
                await asyncio.sleep(random.uniform(0.5, 1.0))
                logger.info("depop reprice {} -> {}", listing_id, new_price)
                return True
            except Exception as exc:
                logger.exception("depop reprice failed: {}", exc)
                return False
            finally:
                await page.close()
