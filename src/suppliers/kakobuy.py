"""Kakobuy agent — same shape as Hoobuy; selectors differ slightly."""
from __future__ import annotations

from decimal import Decimal

from loguru import logger

from src.suppliers.base import BuyerAddress, OrderResult, SupplierBase, Variant
from src.suppliers.hoobuy import Hoobuy


class Kakobuy(Hoobuy, SupplierBase):
    """Alias driver — reuses Hoobuy's agent flow. Kakobuy's UI diverges mostly on
    stylesheet and base URL; the parse-link → cart → checkout → QC sequence is
    identical, so this driver inherits the whole class and overrides only the
    base URLs where needed."""

    name = "kakobuy"

    _CREATE_URL = "https://www.kakobuy.com/order/create"
    _DETAIL_URL = "https://www.kakobuy.com/order/detail?orderSn={ref}"

    async def place_order(
        self,
        *,
        product_url: str,
        variant: Variant,
        buyer: BuyerAddress,
        order_ref: str,
        max_price_usd: Decimal | float | None = None,
    ) -> OrderResult:
        logger.debug("kakobuy place_order delegating to hoobuy flow")
        return await super().place_order(
            product_url=product_url,
            variant=variant,
            buyer=buyer,
            order_ref=order_ref,
            max_price_usd=max_price_usd,
        )
