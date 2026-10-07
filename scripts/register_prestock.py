"""Record a batch of prestocked inventory sitting at the reshipper.

Usage:
    python -m scripts.register_prestock \\
        --sku CRTZ-ALC-CARGO --size L --reshipper shipito \\
        --item-id ship-12345 --qty 3 --unit-cost 24.50

Marks the SKU stocking_mode='prestocked' so future sales ship same-day.
"""
from __future__ import annotations

import argparse
import asyncio
import datetime as dt
from decimal import Decimal

from loguru import logger
from sqlalchemy import update
from sqlalchemy.dialects.postgresql import insert as pg_insert

from src.db.models import PrestockedInventory, ProductCatalog
from src.db.session import session_scope
from src.utils.logging import configure_logging


async def _run(sku: str, size: str, reshipper: str, item_id: str, qty: int, unit_cost: Decimal) -> None:
    async with session_scope() as sess:
        await sess.execute(
            pg_insert(PrestockedInventory.__table__)
            .values(
                sku=sku,
                size=size,
                reshipper=reshipper,
                reshipper_item_id=item_id,
                qty_available=qty,
                unit_cost_landed_usd=unit_cost,
                received_at=dt.datetime.now(tz=dt.timezone.utc),
            )
            .on_conflict_do_update(
                constraint="uq_prestocked_sku_size_reshipper",
                set_={
                    "reshipper_item_id": item_id,
                    "qty_available": PrestockedInventory.__table__.c.qty_available + qty,
                    "unit_cost_landed_usd": unit_cost,
                    "received_at": dt.datetime.now(tz=dt.timezone.utc),
                },
            )
        )
        await sess.execute(
            update(ProductCatalog)
            .where(ProductCatalog.sku == sku)
            .values(stocking_mode="prestocked")
        )
    logger.info("prestock registered sku={} size={} qty={}", sku, size, qty)


def main() -> None:
    configure_logging()
    p = argparse.ArgumentParser()
    p.add_argument("--sku", required=True)
    p.add_argument("--size", required=True)
    p.add_argument("--reshipper", default="shipito")
    p.add_argument("--item-id", required=True)
    p.add_argument("--qty", type=int, required=True)
    p.add_argument("--unit-cost", required=True, help="landed cost USD")
    args = p.parse_args()
    asyncio.run(
        _run(args.sku, args.size, args.reshipper, args.item_id, args.qty, Decimal(args.unit_cost))
    )


if __name__ == "__main__":
    main()
