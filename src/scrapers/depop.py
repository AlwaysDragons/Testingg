"""Depop market scraper — browse + search results.

Reads listings from category + search pages. No login required.
Rotates through the pool's unauthenticated path (fresh context,
no stored session).
"""
from __future__ import annotations

import re
from decimal import Decimal, InvalidOperation
from urllib.parse import quote_plus

from loguru import logger
from selectolax.lexbor import LexborHTMLParser as HTMLParser

from src.marketplaces._common import utcnow
from src.playwright_pool import pool
from src.scrapers._base import ScrapedListing

SEARCH_URL = "https://www.depop.com/search/?q={q}&sort=newlyListed"
SOLD_SEARCH_URL = "https://www.depop.com/search/?q={q}&isSold=true"

CARD_SELECTOR = "li[data-testid='product-card'] a, a[data-testid*='product'] "
TITLE_ATTR = "aria-label"
PRICE_RE = re.compile(r"\$?([\d]+\.?\d*)")


async def scrape_search(query: str, pages: int = 2, sold: bool = False) -> list[ScrapedListing]:
    out: list[ScrapedListing] = []
    url_tmpl = SOLD_SEARCH_URL if sold else SEARCH_URL
    url = url_tmpl.format(q=quote_plus(query))
    async with pool.session("depop", "scrape-anon", proxy_slot=f"scrape:depop", save_state=False) as ctx:
        page = await ctx.new_page()
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=45_000)
            for _ in range(pages):
                await page.mouse.wheel(0, 4000)
                await page.wait_for_timeout(1200)

            html = await page.content()
            tree = HTMLParser(html)
            for a in tree.css("a[data-testid*='product'], a[href*='/products/']"):
                href = a.attributes.get("href") or ""
                label = a.attributes.get("aria-label") or a.text(strip=True) or ""
                if not href:
                    continue
                m = PRICE_RE.search(label)
                try:
                    price = Decimal(m.group(1)) if m else None
                except InvalidOperation:
                    price = None
                lid = href.rstrip("/").split("/")[-1]
                out.append(
                    ScrapedListing(
                        platform="depop",
                        platform_listing_id=lid,
                        title=label,
                        price_usd=price,
                        seller_handle=None,
                        size=None,
                        category=query,
                        sold=sold,
                        posted_at=None,
                        sold_at=utcnow() if sold else None,
                        url=f"https://www.depop.com{href}" if href.startswith("/") else href,
                        image_url=None,
                    )
                )
            logger.info("depop scrape q={!r} sold={} -> {} listings", query, sold, len(out))
        finally:
            await page.close()
    return out
