from __future__ import annotations

import asyncio
import random

from loguru import logger

from src.db.models import PostingAccount
from src.playwright_pool import pool
from src.posters._selectors import MercariNew as sel
from src.posters.base import PostResult, PosterBase


class MercariPoster(PosterBase):
    name = "mercari"

    async def create_listing(
        self,
        account: PostingAccount,
        *,
        title: str,
        description: str,
        price_usd: float,
        size: str,
        category: str,
        photos: list[str],
        tags: list[str] | None = None,
    ) -> PostResult:
        async with pool.session(
            account.platform, account.handle, proxy_slot=account.proxy_slot
        ) as ctx:
            page = await ctx.new_page()
            try:
                await page.goto(sel.URL, wait_until="domcontentloaded", timeout=45_000)
                if photos:
                    await page.locator(sel.PHOTOS_INPUT).first.set_input_files(photos[:10])
                    await asyncio.sleep(random.uniform(1.5, 2.5))
                await page.locator(sel.TITLE_INPUT).first.fill(title)
                await page.locator(sel.DESC_TEXTAREA).first.fill(description)
                try:
                    await page.locator(sel.CATEGORY_SELECT).first.click()
                    await page.locator(f"li:has-text('{category}')").first.click()
                except Exception:
                    pass
                try:
                    await page.locator(sel.SIZE_SELECT).first.click()
                    await page.locator(f"li:has-text('{size}')").first.click()
                except Exception:
                    pass
                await page.locator(sel.PRICE_INPUT).first.fill(f"{price_usd:.2f}")
                await page.locator(sel.PUBLISH).first.click()
                await page.wait_for_selector(sel.SUCCESS_LINK, timeout=30_000)
                link = page.locator(sel.SUCCESS_LINK).first
                url = await link.get_attribute("href") or ""
                if url.startswith("/"):
                    url = "https://www.mercari.com" + url
                listing_id = url.rstrip("/").split("/")[-1]
                logger.info("mercari listing live: {}", listing_id)
                return PostResult(ok=True, platform_listing_id=listing_id, url=url)
            except Exception as exc:
                logger.exception("mercari poster: {}", exc)
                return PostResult(ok=False, error=f"{type(exc).__name__}: {exc}")
            finally:
                await page.close()
