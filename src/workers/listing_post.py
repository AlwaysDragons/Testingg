"""Create a listing for a SKU on one or all three platforms.

Pipeline: pick account → compute price → generate title/desc → build photo set
→ call poster → persist our_listings row.
"""
from __future__ import annotations

import asyncio
import datetime as dt

from loguru import logger
from sqlalchemy import select

from src.config import settings
from src.db.models import OurListing, ProductCatalog
from src.db.session import session_scope
from src.generators.description import generate_description
from src.generators.photos import build_photo_set
from src.generators.pricing import compute_initial_price
from src.generators.title import generate_title
from src.posters.rotation import pick_account, poster_for, record_posted


async def _load_sku(sku: str) -> ProductCatalog | None:
    async with session_scope() as sess:
        return (
            await sess.execute(select(ProductCatalog).where(ProductCatalog.sku == sku))
        ).scalar_one_or_none()


async def _record_listing(**fields) -> int:
    async with session_scope() as sess:
        result = await sess.execute(
            OurListing.__table__.insert().values(**fields).returning(OurListing.id)
        )
        return int(result.scalar_one())


async def post_sku(sku: str, platforms: list[str] | None = None, size: str | None = None) -> dict[str, dict]:
    product = await _load_sku(sku)
    if product is None:
        return {"error": f"sku {sku} not in catalog"}

    sizes = [size] if size else (product.sizes or ["one size"])
    platforms = platforms or ["depop", "grailed", "mercari"]
    outcomes: dict[str, dict] = {}

    for platform in platforms:
        account = await pick_account(platform)
        if account is None:
            outcomes[platform] = {"ok": False, "error": "no eligible posting account"}
            continue
        chosen_size = sizes[0]
        price = await compute_initial_price(sku, platform)
        if price is None:
            outcomes[platform] = {"ok": False, "error": "no supplier cost — cannot price"}
            continue

        salt = f"{platform}:{account.handle}:{dt.date.today().isoformat()}"
        title = generate_title(
            display_name=product.display_name,
            variant_group=product.variant_group,
            size=chosen_size,
            condition="new w/o tags",
            sku=sku,
            salt=salt,
        )
        tags = [product.category, product.display_name, product.variant_group or ""]
        description = generate_description(
            display_name=product.display_name,
            variant_group=product.variant_group,
            size=chosen_size,
            condition="new w/o tags",
            sku=sku,
            salt=salt,
            tags=[t for t in tags if t],
        )
        photos = build_photo_set(
            sku=sku,
            raw_dir=f"/data/photos/raw/{sku}",
            out_dir="/data/photos/processed",
            salt=salt,
            count=5,
            backgrounds_dir="/data/photos/backgrounds",
        )

        poster = poster_for(platform)
        result = await poster.create_listing(
            account,
            title=title,
            description=description,
            price_usd=float(price),
            size=chosen_size,
            category=product.category,
            photos=photos,
            tags=[t for t in tags if t],
        )

        if not result.ok:
            outcomes[platform] = {"ok": False, "error": result.error}
            continue

        listing_id = await _record_listing(
            sku=sku,
            platform=platform,
            platform_listing_id=result.platform_listing_id,
            posting_account_id=account.id,
            url=result.url,
            price_usd=price,
            original_price_usd=price,
            status="active",
            photo_set=photos,
            title=title,
            description=description,
            posted_at=dt.datetime.now(tz=dt.timezone.utc),
        )
        await record_posted(account.id)
        outcomes[platform] = {
            "ok": True,
            "listing_id": listing_id,
            "platform_listing_id": result.platform_listing_id,
            "url": result.url,
            "price": float(price),
            "account": account.handle,
        }
        logger.info("posted {} on {} as account={} -> {}", sku, platform, account.handle, result.url)
    return outcomes


def run(sku: str, platforms: list[str] | None = None) -> dict:
    return asyncio.run(post_sku(sku, platforms))
