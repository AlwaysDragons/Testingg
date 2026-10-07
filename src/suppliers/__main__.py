"""CLI test harness for supplier drivers.

Usage:
    python -m src.suppliers test_order --source dhgate --url <product_url> \\
        --color Black --size M --to "Jane Doe|123 Main St||Austin|TX|78701|US|+15125551234"
"""
from __future__ import annotations

import argparse
import asyncio
from decimal import Decimal

from loguru import logger

from src.suppliers.base import BuyerAddress, Variant
from src.suppliers.router import get_driver
from src.utils.logging import configure_logging


def _parse_address(blob: str) -> BuyerAddress:
    parts = blob.split("|")
    if len(parts) < 6:
        raise SystemExit("--to must be 'name|line1|line2|city|state|postal|country|phone'")
    while len(parts) < 8:
        parts.append("")
    return BuyerAddress(
        recipient=parts[0],
        line1=parts[1],
        line2=parts[2] or None,
        city=parts[3],
        state=parts[4],
        postal_code=parts[5],
        country=parts[6] or "US",
        phone=parts[7] or None,
    )


async def _run(args: argparse.Namespace) -> None:
    driver = get_driver(args.source)
    buyer = _parse_address(args.to)
    variant = Variant(color=args.color, size=args.size, qty=args.qty)

    result = await driver.place_order(
        product_url=args.url,
        variant=variant,
        buyer=buyer,
        order_ref=args.ref,
        max_price_usd=Decimal(args.max_price) if args.max_price else None,
    )
    logger.info("result: ok={} ref={} cost={} error={}", result.ok, result.supplier_order_ref, result.cost_usd, result.error)


def main() -> None:
    configure_logging()
    parser = argparse.ArgumentParser(prog="python -m src.suppliers")
    sub = parser.add_subparsers(dest="cmd", required=True)

    test = sub.add_parser("test_order", help="place a one-off order through a driver")
    test.add_argument("--source", required=True, choices=["dhgate", "hoobuy", "kakobuy"])
    test.add_argument("--url", required=True, help="supplier product URL")
    test.add_argument("--color", default=None)
    test.add_argument("--size", default=None)
    test.add_argument("--qty", type=int, default=1)
    test.add_argument("--to", required=True, help="pipe-delimited buyer address")
    test.add_argument("--ref", default="TEST-0001")
    test.add_argument("--max-price", default=None, help="price cap USD")

    args = parser.parse_args()
    if args.cmd == "test_order":
        asyncio.run(_run(args))


if __name__ == "__main__":
    main()
