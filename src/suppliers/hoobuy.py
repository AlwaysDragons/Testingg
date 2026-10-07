from __future__ import annotations

import asyncio
import random
import re
from decimal import Decimal, InvalidOperation

from loguru import logger
from playwright.async_api import Page, TimeoutError as PWTimeout

from src.playwright_pool import pool
from src.suppliers.base import DROPSHIP_NOTES, BuyerAddress, OrderResult, SupplierBase, Variant
from src.suppliers.selectors import hoobuy as sel

PRICE_RE = re.compile(r"[\d]+\.?\d*")


class Hoobuy(SupplierBase):
    """Hoobuy agent — paste link, parse, add to cart, checkout.

    Agent flow adds a QC step: after the item arrives at the warehouse,
    Hoobuy posts photos; the order holds in 'qc_pending' status until
    the operator presses Approve from Telegram. `approve_qc` + `reject_qc`
    are called from the Telegram dispatcher after a human eyeballs photos.
    """

    name = "hoobuy"

    async def place_order(
        self,
        *,
        product_url: str,
        variant: Variant,
        buyer: BuyerAddress,
        order_ref: str,
        max_price_usd: Decimal | float | None = None,
    ) -> OrderResult:
        cap = Decimal(str(max_price_usd)) if max_price_usd is not None else None

        async with pool.session("hoobuy", "hoobuy", headless=True) as context:
            page = await context.new_page()
            try:
                await page.goto("https://www.hoobuy.com/order/create", wait_until="domcontentloaded", timeout=45_000)

                link_input = page.locator(sel.PRODUCT_URL_INPUT).first
                await link_input.fill(product_url)
                await page.locator(sel.PARSE_LINK_BUTTON).first.click()
                await page.wait_for_selector(sel.PRODUCT_PRICE, timeout=20_000)

                price = await self._parse_price(page)
                if price is None:
                    return OrderResult(ok=False, error="price parse failed")
                if cap is not None and price > cap:
                    return OrderResult(
                        ok=False,
                        error=f"price_breach: {price} > {cap}",
                        meta={"actual": str(price), "cap": str(cap)},
                    )

                if variant.color:
                    v = page.locator(sel.VARIANT_COLOR.format(color=variant.color)).first
                    if await v.count():
                        await v.click()
                if variant.size:
                    v = page.locator(sel.VARIANT_SIZE.format(size=variant.size)).first
                    if await v.count():
                        await v.click()

                qty = page.locator(sel.QTY_INPUT).first
                if await qty.count():
                    await qty.fill(str(variant.qty))

                await page.locator(sel.ADD_TO_CART).first.click()
                await asyncio.sleep(random.uniform(0.5, 1.0))

                await page.locator(sel.CART_CHECKOUT).first.click()
                await page.wait_for_selector(sel.ADDRESS_RECIPIENT, timeout=20_000)

                await page.locator(sel.ADDRESS_RECIPIENT).first.fill(buyer.recipient)
                await page.locator(sel.ADDRESS_LINE1).first.fill(
                    buyer.line1 + ((" " + buyer.line2) if buyer.line2 else "")
                )
                await page.locator(sel.ADDRESS_CITY).first.fill(buyer.city)
                await page.locator(sel.ADDRESS_STATE).first.fill(buyer.state)
                await page.locator(sel.ADDRESS_POSTAL).first.fill(buyer.postal_code)
                try:
                    await page.locator(sel.ADDRESS_COUNTRY).first.select_option(buyer.country)
                except Exception:
                    pass
                if buyer.phone:
                    phone = page.locator(sel.ADDRESS_PHONE).first
                    if await phone.count():
                        await phone.fill(buyer.phone)

                remark = page.locator(sel.REMARK_TEXTAREA).first
                if await remark.count():
                    await remark.fill(random.choice(DROPSHIP_NOTES))

                bal = page.locator(sel.PAY_WITH_BALANCE).first
                if await bal.count():
                    await bal.click()

                await page.locator(sel.CONFIRM_ORDER).first.click()
                await page.wait_for_load_state("domcontentloaded", timeout=45_000)

                ref_loc = page.locator(sel.ORDER_REF).first
                ref = (await ref_loc.inner_text(timeout=5_000)).strip() if await ref_loc.count() else None
                if not ref:
                    return OrderResult(ok=False, error="no order ref")

                logger.info("hoobuy order placed ref={} price={} (awaiting QC)", ref, price)
                return OrderResult(
                    ok=True,
                    supplier_order_ref=ref,
                    cost_usd=price,
                    meta={"qc_required": True, "shop_ref": order_ref},
                )
            except Exception as exc:
                logger.exception("hoobuy order failed: {}", exc)
                return OrderResult(ok=False, error=f"{type(exc).__name__}: {exc}")

    async def _parse_price(self, page: Page) -> Decimal | None:
        loc = page.locator(sel.PRODUCT_PRICE).first
        try:
            if await loc.count():
                txt = (await loc.inner_text(timeout=2_000)).strip()
                m = PRICE_RE.search(txt)
                if m:
                    return Decimal(m.group(0))
        except (PWTimeout, InvalidOperation):
            pass
        return None

    async def approve_qc(self, supplier_order_ref: str) -> bool:
        return await self._qc_action(supplier_order_ref, approve=True)

    async def reject_qc(self, supplier_order_ref: str) -> bool:
        return await self._qc_action(supplier_order_ref, approve=False)

    async def _qc_action(self, supplier_order_ref: str, *, approve: bool) -> bool:
        async with pool.session("hoobuy", "hoobuy", headless=True) as context:
            page = await context.new_page()
            try:
                await page.goto(
                    f"https://www.hoobuy.com/order/detail?orderSn={supplier_order_ref}",
                    wait_until="domcontentloaded",
                    timeout=30_000,
                )
                btn = page.locator(
                    sel.QC_APPROVE_BUTTON if approve else sel.QC_REJECT_BUTTON
                ).first
                if not await btn.count():
                    logger.warning("qc button not visible for {}", supplier_order_ref)
                    return False
                await btn.click()
                await asyncio.sleep(1.0)
                return True
            except Exception as exc:
                logger.exception("qc action failed: {}", exc)
                return False

    async def fetch_tracking(self, supplier_order_ref: str) -> dict[str, str | None]:
        async with pool.session("hoobuy", "hoobuy", headless=True) as context:
            page = await context.new_page()
            try:
                await page.goto(
                    f"https://www.hoobuy.com/order/detail?orderSn={supplier_order_ref}",
                    wait_until="domcontentloaded",
                    timeout=30_000,
                )
                for s in ("span.tracking-number", "a[href*='track']", "div.logistics .no"):
                    loc = page.locator(s).first
                    try:
                        if await loc.count():
                            return {
                                "tracking_number": (await loc.inner_text(timeout=1_500)).strip(),
                                "carrier": None,
                            }
                    except PWTimeout:
                        continue
                return {"tracking_number": None, "carrier": None}
            finally:
                await page.close()
