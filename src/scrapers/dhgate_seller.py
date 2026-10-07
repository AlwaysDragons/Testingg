"""DHgate seller discovery — top-rated sellers for a category.

Scores by rating × transaction_count × response_rate so dhgate_sellers table
seeds with high-trust sellers for future product-source expansion.
"""
from __future__ import annotations

import re
from urllib.parse import quote_plus

from loguru import logger
from selectolax.lexbor import LexborHTMLParser as HTMLParser

from src.playwright_pool import pool

RATING_RE = re.compile(r"([\d.]+)")
TX_RE = re.compile(r"([\d,]+)")


async def discover_sellers(category: str, pages: int = 2) -> list[dict]:
    out: list[dict] = []
    url = f"https://www.dhgate.com/wholesale/search.do?searchkey={quote_plus(category)}&sortby=sale"
    async with pool.session("dhgate", "dhgate", save_state=False) as ctx:
        page = await ctx.new_page()
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=45_000)
            for _ in range(pages):
                await page.mouse.wheel(0, 4000)
                await page.wait_for_timeout(1500)
            html = await page.content()
            tree = HTMLParser(html)
            seen: set[str] = set()
            for prod in tree.css("div.gallery-main .listitem, div.pro-item"):
                seller_link = prod.css_first("a.seller-link, a[href*='store']")
                if not seller_link:
                    continue
                href = seller_link.attributes.get("href") or ""
                m = re.search(r"/store/(\d+)", href)
                if not m:
                    continue
                sid = m.group(1)
                if sid in seen:
                    continue
                seen.add(sid)
                name = seller_link.text(strip=True)
                rating_el = prod.css_first("span.seller-rate, span.rating")
                tx_el = prod.css_first("span.sold-num, span.transactions")
                rating = RATING_RE.search(rating_el.text(strip=True)) if rating_el else None
                tx = TX_RE.search(tx_el.text(strip=True)) if tx_el else None
                out.append(
                    {
                        "seller_id": sid,
                        "store_name": name,
                        "store_url": href if href.startswith("http") else f"https:{href}",
                        "rating": float(rating.group(1)) if rating else None,
                        "transaction_count": (
                            int(tx.group(1).replace(",", "")) if tx else None
                        ),
                    }
                )
            logger.info("dhgate seller discovery for {!r}: {} sellers", category, len(out))
        finally:
            await page.close()
    return out
