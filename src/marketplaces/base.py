from __future__ import annotations

import datetime as dt
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any

from src.db.models import PostingAccount


@dataclass
class SaleEvent:
    platform: str
    platform_sale_id: str
    platform_listing_id: str | None
    buyer_handle: str | None
    sale_price_usd: Decimal | None
    sold_at: dt.datetime | None
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass
class DMMessage:
    platform: str
    buyer_handle: str
    body: str
    sent_at: dt.datetime
    related_listing_id: str | None = None


class MarketplaceBase(ABC):
    name: str = "base"

    @abstractmethod
    async def poll_sold_items(self, account: PostingAccount) -> list[SaleEvent]: ...

    @abstractmethod
    async def fetch_buyer_address(
        self, account: PostingAccount, sale_id: str
    ) -> dict[str, Any] | None: ...

    @abstractmethod
    async def push_tracking(
        self, account: PostingAccount, sale_id: str, tracking: str, carrier: str
    ) -> bool: ...

    @abstractmethod
    async def send_dm(
        self, account: PostingAccount, buyer_handle: str, body: str
    ) -> bool: ...

    @abstractmethod
    async def read_dms(self, account: PostingAccount) -> list[DMMessage]: ...

    @abstractmethod
    async def update_listing_price(
        self, account: PostingAccount, listing_id: str, new_price: float
    ) -> bool: ...
