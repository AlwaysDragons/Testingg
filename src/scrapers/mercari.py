"""Mercari market scraper."""
from __future__ import annotations

import re
from decimal import Decimal, InvalidOperation
from urllib.parse import quote_plus

from loguru import logger
from selectolax.parser import HTMLParser

from src.marketplaces._common import utcnow
from src.playwright_pool import pool
from src.scrapers._base import ScrapedListing

SEARCH_URL = "https://www.mercari.com/search/?keyword={q}&status=on_sale"
SOLD_URL = "https://www.mercari.com/search/?keyword={q}&status=sold_out"
PRICE_RE = re.compile(r"[\d]+\.?\d*")


async def scrape_search(query: str, pages: int = 2, sold: bool = False) -> list[ScrapedListing]:
    out: list[ScrapedListing] = []
    url = (SOLD_URL if sold else SEARCH_URL).format(q=quote_plus(query))
    async with pool.session("mercari", "scrape-anon", save_state=False) as ctx:
        page = await ctx.new_page()
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=45_000)
            for _ in range(pages):
                await page.mouse.wheel(0, 4000)
                await page.wait_for_timeout(1200)
            html = await page.content()
            tree = HTMLParser(html)
            for card in tree.css("li[data-testid='ItemCell'] a, a[data-testid*='Item']"):
                href = card.attributes.get("href") or ""
                title_el = card.css_first("p[data-testid='ItemCell__ItemThumbnail__name']")
                price_el = card.css_first("p[data-testid='ItemCell__ItemThumbnail__price']")
                title = title_el.text(strip=True) if title_el else card.text(strip=True)
                price_txt = price_el.text(strip=True) if price_el else ""
                m = PRICE_RE.search(price_txt)
                try:
                    price = Decimal(m.group(0)) if m else None
                except InvalidOperation:
                    price = None
                lid = href.rstrip("/").split("/")[-1]
                if not lid:
                    continue
                out.append(
                    ScrapedListing(
                        platform="mercari",
                        platform_listing_id=lid,
                        title=title,
                        price_usd=price,
                        seller_handle=None,
                        size=None,
                        category=query,
                        sold=sold,
                        posted_at=None,
                        sold_at=utcnow() if sold else None,
                        url=f"https://www.mercari.com{href}" if href.startswith("/") else href,
                        image_url=None,
                    )
                )
            logger.info("mercari scrape q={!r} sold={} -> {}", query, sold, len(out))
        finally:
            await page.close()
    return out
