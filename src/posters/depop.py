from __future__ import annotations

import asyncio
import random

from loguru import logger

from src.db.models import PostingAccount
from src.playwright_pool import pool
from src.posters._selectors import DepopNew as sel
from src.posters.base import PostResult, PosterBase


class DepopPoster(PosterBase):
    name = "depop"

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
            account.platform, account.handle, proxy_slot=account.proxy_slot, headless=True
        ) as ctx:
            page = await ctx.new_page()
            try:
                await page.goto(sel.URL, wait_until="domcontentloaded", timeout=45_000)

                if photos:
                    await page.locator(sel.PHOTOS_INPUT).first.set_input_files(photos[:8])
                    await asyncio.sleep(random.uniform(1.5, 2.5))

                await page.locator(sel.TITLE_INPUT).first.fill(title)
                await page.locator(sel.DESC_TEXTAREA).first.fill(description)

                try:
                    await page.locator(sel.CATEGORY_SELECT).first.click(timeout=5_000)
                    await page.locator(f"li:has-text('{category}')").first.click(timeout=5_000)
                except Exception:
                    logger.debug("depop category: fallback — manual pick needed")

                try:
                    await page.locator(sel.SIZE_SELECT).first.click(timeout=5_000)
                    await page.locator(f"li:has-text('{size}')").first.click(timeout=5_000)
                except Exception:
                    pass

                await page.locator(sel.PRICE_INPUT).first.fill(f"{price_usd:.2f}")

                await page.locator(sel.PUBLISH_BUTTON).first.click()
                try:
                    await page.wait_for_selector(sel.LISTING_SUCCESS, timeout=30_000)
                    link = page.locator(sel.LISTING_SUCCESS).first
                    url = await link.get_attribute("href") or ""
                    if url.startswith("/"):
                        url = "https://www.depop.com" + url
                    listing_id = url.rstrip("/").split("/")[-1]
                    logger.info("depop listing live: {} ({})", listing_id, url)
                    return PostResult(ok=True, platform_listing_id=listing_id, url=url)
                except Exception as exc:
                    return PostResult(ok=False, error=f"publish-wait failed: {exc}")
            except Exception as exc:
                logger.exception("depop poster: {}", exc)
                return PostResult(ok=False, error=f"{type(exc).__name__}: {exc}")
            finally:
                await page.close()
