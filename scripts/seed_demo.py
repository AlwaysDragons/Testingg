"""Seed one demo SKU + supplier source so the stack has data to work with
on first boot. Idempotent — safe to re-run.

Run inside the container:
    docker compose run --rm worker python -m scripts.seed_demo
"""
from __future__ import annotations

import asyncio
from decimal import Decimal

from loguru import logger
from sqlalchemy.dialects.postgresql import insert as pg_insert

from src.db.models import CompetitorSeller, ProductCatalog, ProductSource
from src.db.session import session_scope
from src.utils.logging import configure_logging


DEMO_SKU = "DEMO-TEE-BLACK"


async def _seed() -> None:
    async with session_scope() as sess:
        await sess.execute(
            pg_insert(ProductCatalog.__table__)
            .values(
                sku=DEMO_SKU,
                display_name="Demo Essentials Tee",
                category="menswear/tops",
                variant_group="black",
                sizes=["S", "M", "L", "XL"],
                stocking_mode="dropship",
            )
            .on_conflict_do_nothing(index_elements=["sku"])
        )
        await sess.execute(
            pg_insert(ProductSource.__table__)
            .values(
                sku=DEMO_SKU,
                source="dhgate",
                product_url="https://www.dhgate.com/product/demo-placeholder/000000000.html",
                color_option="Black",
                size_option="M",
                expected_price_usd=Decimal("12.00"),
                max_price_usd=Decimal("18.00"),
                avg_ship_days=10,
                quality_tier="tier-2",
                priority=100,
                status="active",
            )
            .on_conflict_do_nothing(
                index_elements=["sku", "source", "product_url"]
            )
        )
        await sess.execute(
            pg_insert(CompetitorSeller.__table__)
            .values(
                platform="depop",
                seller_handle="demo_competitor",
                categories=["streetwear"],
                monitored=False,
            )
            .on_conflict_do_nothing(
                index_elements=["platform", "seller_handle"]
            )
        )
    logger.info("demo seed done — try /digest in Telegram")


def main() -> None:
    configure_logging()
    asyncio.run(_seed())


if __name__ == "__main__":
    main()
