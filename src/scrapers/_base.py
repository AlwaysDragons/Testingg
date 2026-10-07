"""Shared helpers for market-intel scrapers."""
from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any


@dataclass
class ScrapedListing:
    platform: str
    platform_listing_id: str
    title: str
    price_usd: Decimal | None
    seller_handle: str | None
    size: str | None
    category: str | None
    sold: bool
    posted_at: dt.datetime | None
    sold_at: dt.datetime | None
    url: str
    image_url: str | None
    raw: dict[str, Any] = field(default_factory=dict)
