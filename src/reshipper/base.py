from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from decimal import Decimal


@dataclass
class ShipResult:
    ok: bool
    tracking_number: str | None = None
    carrier: str | None = None
    reshipper_shipment_id: str | None = None
    fee_usd: Decimal | None = None
    error: str | None = None


class ReshipperBase(ABC):
    name: str = "base"

    @abstractmethod
    async def ship(self, *, item_id: str, buyer: dict, service: str | None = None) -> ShipResult: ...

    @abstractmethod
    async def receive_notify(self, item_id: str) -> dict: ...
