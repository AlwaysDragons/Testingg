"""Grailed market scraper — Algolia-backed search page."""
from __future__ import annotations

import re
from decimal import Decimal, InvalidOperation
from urllib.parse import quote_plus

from loguru import logger
from selectolax.parser import HTMLParser

from src.marketplaces._common import utcnow
from src.playwright_pool import pool
from src.scrapers._base import ScrapedListing

SEARCH_URL = "https://www.grailed.com/shop?query={q}&sold=false"
SOLD_URL = "https://www.grailed.com/shop?query={q}&sold=true"
PRICE_RE = re.compile(r"[\d]+\.?\d*")


async def scrape_search(query: str, pages: int = 2, sold: bool = False) -> list[ScrapedListing]:
    out: list[ScrapedListing] = []
    url = (SOLD_URL if sold else SEARCH_URL).format(q=quote_plus(query))
    async with pool.session("grailed", "scrape-anon", save_state=False) as ctx:
        page = await ctx.new_page()
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=45_000)
            for _ in range(pages):
                await page.mouse.wheel(0, 4000)
                await page.wait_for_timeout(1200)
            html = await page.content()
            tree = HTMLParser(html)
            for card in tree.css("div[class*='feed-item'] a, a[href*='/listings/']"):
                href = card.attributes.get("href") or ""
                title_el = card.css_first("p.listing-title, span[class*='title']")
                price_el = card.css_first("p.listing-price, span[class*='price']")
                size_el = card.css_first("p.listing-size, span[class*='size']")
                title = title_el.text(strip=True) if title_el else ""
                price_txt = price_el.text(strip=True) if price_el else ""
                size = size_el.text(strip=True) if size_el else None
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
                        platform="grailed",
                        platform_listing_id=lid,
                        title=title,
                        price_usd=price,
                        seller_handle=None,
                        size=size,
                        category=query,
                        sold=sold,
                        posted_at=None,
                        sold_at=utcnow() if sold else None,
                        url=f"https://www.grailed.com{href}" if href.startswith("/") else href,
                        image_url=None,
                    )
                )
            logger.info("grailed scrape q={!r} sold={} -> {}", query, sold, len(out))
        finally:
            await page.close()
    return out
