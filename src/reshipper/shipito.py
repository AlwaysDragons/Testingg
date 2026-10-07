"""Shipito API client.

Public REST API — exact endpoints and body shape vary a bit by account tier.
The methods here match the current docs; if endpoints drift, this is the one
file to edit.
"""
from __future__ import annotations

from decimal import Decimal, InvalidOperation

import httpx
from loguru import logger

from src.config import settings
from src.reshipper.base import ReshipperBase, ShipResult


class Shipito(ReshipperBase):
    name = "shipito"

    BASE_URL = "https://www.shipito.com/api/v2"

    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {settings.shipito_api_key}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        }

    async def ship(
        self, *, item_id: str, buyer: dict, service: str | None = None
    ) -> ShipResult:
        if not settings.shipito_api_key or not settings.shipito_account_id:
            return ShipResult(ok=False, error="shipito api key or account id not configured")
        payload = {
            "account_id": settings.shipito_account_id,
            "mailbox_item_id": item_id,
            "service_name": service or "USPS_PRIORITY",
            "recipient": {
                "name": buyer.get("recipient"),
                "address1": buyer.get("line1"),
                "address2": buyer.get("line2") or "",
                "city": buyer.get("city"),
                "state": buyer.get("state"),
                "postal_code": buyer.get("postal_code"),
                "country": buyer.get("country", "US"),
                "phone": buyer.get("phone") or "",
            },
        }
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                r = await client.post(
                    f"{self.BASE_URL}/packages/outbound",
                    json=payload,
                    headers=self._headers(),
                )
            if r.status_code >= 300:
                return ShipResult(ok=False, error=f"shipito http {r.status_code}: {r.text[:200]}")
            data = r.json()
            try:
                fee = Decimal(str(data.get("total_price", "0"))) if data.get("total_price") else None
            except InvalidOperation:
                fee = None
            return ShipResult(
                ok=True,
                tracking_number=data.get("tracking_number"),
                carrier=data.get("carrier") or "USPS",
                reshipper_shipment_id=str(data.get("shipment_id", "")),
                fee_usd=fee,
            )
        except Exception as exc:
            logger.exception("shipito ship failed: {}", exc)
            return ShipResult(ok=False, error=f"{type(exc).__name__}: {exc}")

    async def receive_notify(self, item_id: str) -> dict:
        try:
            async with httpx.AsyncClient(timeout=15.0) as client:
                r = await client.get(
                    f"{self.BASE_URL}/mailbox/items/{item_id}",
                    headers=self._headers(),
                )
            if r.status_code >= 300:
                return {"error": f"http {r.status_code}", "status": "unknown"}
            return r.json()
        except Exception as exc:
            return {"error": str(exc), "status": "unknown"}
