from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any


@dataclass
class BuyerAddress:
    recipient: str
    line1: str
    line2: str | None
    city: str
    state: str
    postal_code: str
    country: str = "US"
    phone: str | None = None


@dataclass
class Variant:
    color: str | None = None
    size: str | None = None
    qty: int = 1


@dataclass
class OrderResult:
    ok: bool
    supplier_order_ref: str | None = None
    cost_usd: Decimal | None = None
    error: str | None = None
    meta: dict[str, Any] = field(default_factory=dict)


DROPSHIP_NOTES = [
    "Dropship order. Please ship with neutral packaging — no invoice or marketing inserts. Thank you!",
    "This is a dropship fulfillment. Neutral packaging please, no invoice inside. Appreciate it!",
    "Dropshipping order — ship with plain packaging, no promotional materials. Thanks!",
]


class SupplierBase(ABC):
    """Supplier driver contract.

    Every supplier (DHgate, Hoobuy, Kakobuy, future off-platform agents) implements
    this. The fulfillment worker only talks to this interface, so routing swaps
    sources without touching the sold-items pipeline.
    """

    name: str = "base"

    @abstractmethod
    async def place_order(
        self,
        *,
        product_url: str,
        variant: Variant,
        buyer: BuyerAddress,
        order_ref: str,
        max_price_usd: Decimal | float | None = None,
    ) -> OrderResult: ...

    @abstractmethod
    async def fetch_tracking(self, supplier_order_ref: str) -> dict[str, str | None]: ...
