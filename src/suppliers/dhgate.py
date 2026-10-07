from __future__ import annotations

import asyncio
import random
import re
from decimal import Decimal, InvalidOperation

from loguru import logger
from playwright.async_api import BrowserContext, Page, TimeoutError as PWTimeout

from src.playwright_pool import pool
from src.suppliers.base import DROPSHIP_NOTES, BuyerAddress, OrderResult, SupplierBase, Variant
from src.suppliers.selectors import dhgate as sel

PRICE_RE = re.compile(r"[\d]+\.?\d*")


class CaptchaBlock(Exception):
    pass


class StockOut(Exception):
    pass


class PriceBreach(Exception):
    def __init__(self, actual: Decimal, cap: Decimal):
        super().__init__(f"price {actual} exceeds cap {cap}")
        self.actual = actual
        self.cap = cap


class DHgate(SupplierBase):
    name = "dhgate"

    async def _check_captcha(self, page: Page) -> None:
        for marker in sel.CAPTCHA_MARKERS:
            if await page.locator(marker).count():
                raise CaptchaBlock(f"captcha visible: {marker}")

    async def _parse_price(self, page: Page) -> Decimal | None:
        for s in (sel.PRODUCT_PRICE_PRIMARY, sel.PRODUCT_PRICE_FALLBACK):
            loc = page.locator(s).first
            try:
                if await loc.count():
                    txt = (await loc.inner_text(timeout=2000)).strip()
                    m = PRICE_RE.search(txt)
                    if m:
                        return Decimal(m.group(0))
            except (PWTimeout, InvalidOperation):
                continue
        return None

    async def _select_variant(self, page: Page, variant: Variant) -> None:
        if variant.color:
            btn = page.locator(sel.PRODUCT_COLOR_BUTTON.format(color=variant.color)).first
            if await btn.count():
                await btn.click()
                await asyncio.sleep(random.uniform(0.4, 0.9))
        if variant.size:
            select = page.locator(sel.PRODUCT_SIZE_SELECT).first
            if await select.count():
                await select.select_option(label=variant.size)
            else:
                opt = page.locator(f"li[title='{variant.size}'], button:has-text('{variant.size}')").first
                if await opt.count():
                    await opt.click()
            await asyncio.sleep(random.uniform(0.3, 0.7))

        qty = page.locator(sel.PRODUCT_QTY_INPUT).first
        if await qty.count():
            await qty.fill(str(variant.qty))

    async def _fill_shipping(self, page: Page, buyer: BuyerAddress) -> None:
        await page.locator(sel.CHECKOUT_ADDRESS_RECIPIENT).first.fill(buyer.recipient)
        await page.locator(sel.CHECKOUT_ADDRESS_LINE1).first.fill(buyer.line1)
        if buyer.line2:
            l2 = page.locator(sel.CHECKOUT_ADDRESS_LINE2).first
            if await l2.count():
                await l2.fill(buyer.line2)
        await page.locator(sel.CHECKOUT_ADDRESS_CITY).first.fill(buyer.city)
        try:
            await page.locator(sel.CHECKOUT_ADDRESS_STATE).first.select_option(buyer.state)
        except Exception:
            await page.locator(sel.CHECKOUT_ADDRESS_STATE).first.fill(buyer.state)
        await page.locator(sel.CHECKOUT_ADDRESS_POSTAL).first.fill(buyer.postal_code)
        try:
            await page.locator(sel.CHECKOUT_ADDRESS_COUNTRY).first.select_option(buyer.country)
        except Exception:
            pass
        if buyer.phone:
            phone = page.locator(sel.CHECKOUT_ADDRESS_PHONE).first
            if await phone.count():
                await phone.fill(buyer.phone)

    async def _pick_fastest_shipping(self, page: Page) -> None:
        """Prefer US warehouse → DHL → ePacket → China Post, by label match."""
        radios = page.locator(sel.CHECKOUT_SHIPPING_METHOD_RADIO)
        n = await radios.count()
        order = ("US Warehouse", "DHL", "ePacket", "China Post")
        picks: dict[str, int] = {}
        for i in range(n):
            r = radios.nth(i)
            rid = await r.get_attribute("id") or ""
            label = page.locator(sel.CHECKOUT_SHIPPING_METHOD_LABEL.format(radio_id=rid))
            try:
                txt = (await label.inner_text(timeout=1500)) if await label.count() else ""
            except PWTimeout:
                txt = ""
            for pref in order:
                if pref.lower() in txt.lower() and pref not in picks:
                    picks[pref] = i
        for pref in order:
            if pref in picks:
                await radios.nth(picks[pref]).check()
                logger.debug("shipping method picked: {}", pref)
                return
        if n:
            await radios.first.check()

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

        async with pool.session("dhgate", "dhgate", headless=True) as context:
            page = await context.new_page()
            try:
                await page.goto(product_url, wait_until="domcontentloaded", timeout=45_000)
                await self._check_captcha(page)

                if await page.locator(sel.STOCK_OUT_MARKER).count():
                    raise StockOut("product marked out of stock")

                price = await self._parse_price(page)
                if price is None:
                    return OrderResult(ok=False, error="could not parse product price")
                if cap is not None and price > cap:
                    raise PriceBreach(price, cap)

                await self._select_variant(page, variant)
                await asyncio.sleep(random.uniform(0.6, 1.2))

                await page.locator(sel.PRODUCT_BUY_NOW).first.click()
                await page.wait_for_load_state("domcontentloaded", timeout=30_000)
                await self._check_captcha(page)

                await self._fill_shipping(page, buyer)
                await page.locator(sel.CHECKOUT_ADDRESS_SAVE).first.click()
                await asyncio.sleep(random.uniform(0.5, 1.1))

                await self._pick_fastest_shipping(page)

                note = page.locator(sel.CHECKOUT_MESSAGE_TEXTAREA).first
                if await note.count():
                    await note.fill(random.choice(DROPSHIP_NOTES))

                final_price = await self._parse_total(page) or price

                if cap is not None and final_price > cap * Decimal("1.10"):
                    raise PriceBreach(final_price, cap)

                await page.locator(sel.CHECKOUT_PAY_BUTTON).first.click()
                try:
                    await page.locator(sel.CHECKOUT_PAY_CONFIRM).first.click(timeout=15_000)
                except PWTimeout:
                    pass
                await page.wait_for_load_state("domcontentloaded", timeout=45_000)
                await self._check_captcha(page)

                ref = await self._extract_order_ref(page)
                if not ref:
                    return OrderResult(
                        ok=False, error="order placed but no reference captured"
                    )
                logger.info("dhgate order placed ref={} price={}", ref, final_price)
                return OrderResult(
                    ok=True,
                    supplier_order_ref=ref,
                    cost_usd=final_price,
                    meta={"shop_ref": order_ref},
                )

            except CaptchaBlock as exc:
                shot = f"/data/dispute_packets/captcha-{order_ref}.png"
                try:
                    await page.screenshot(path=shot, full_page=True)
                except Exception:
                    shot = ""
                logger.error("dhgate captcha for {}: {} (screenshot={})", order_ref, exc, shot)
                return OrderResult(ok=False, error=f"captcha: {exc}", meta={"screenshot": shot})
            except StockOut as exc:
                return OrderResult(ok=False, error=f"stock_out: {exc}")
            except PriceBreach as exc:
                return OrderResult(ok=False, error=f"price_breach: {exc}", meta={
                    "actual": str(exc.actual),
                    "cap": str(exc.cap),
                })
            except Exception as exc:
                logger.exception("dhgate order failed: {}", exc)
                return OrderResult(ok=False, error=f"{type(exc).__name__}: {exc}")

    async def _parse_total(self, page: Page) -> Decimal | None:
        loc = page.locator(sel.PRICE_FINAL).first
        try:
            if await loc.count():
                txt = (await loc.inner_text(timeout=2000)).strip()
                m = PRICE_RE.search(txt)
                if m:
                    return Decimal(m.group(0))
        except (PWTimeout, InvalidOperation):
            pass
        return None

    async def _extract_order_ref(self, page: Page) -> str | None:
        loc = page.locator(sel.ORDER_CONFIRMATION_REF).first
        try:
            if await loc.count():
                return (await loc.inner_text(timeout=3000)).strip()
        except PWTimeout:
            pass
        return None

    async def fetch_tracking(self, supplier_order_ref: str) -> dict[str, str | None]:
        """Poll the DHgate order detail page for tracking number + carrier."""
        async with pool.session("dhgate", "dhgate", headless=True) as context:
            page = await context.new_page()
            try:
                url = f"https://www.dhgate.com/orderdetail.html?orderNo={supplier_order_ref}"
                await page.goto(url, wait_until="domcontentloaded", timeout=30_000)
                tracking = await self._extract_tracking(page)
                carrier = await self._extract_carrier(page)
                return {"tracking_number": tracking, "carrier": carrier}
            finally:
                await page.close()

    async def _extract_tracking(self, page: Page) -> str | None:
        for s in (
            "span.tracking-no",
            "a[href*='tracking']",
            "div.logistics-info .number",
        ):
            loc = page.locator(s).first
            try:
                if await loc.count():
                    txt = (await loc.inner_text(timeout=1500)).strip()
                    if txt and len(txt) >= 6:
                        return txt
            except PWTimeout:
                continue
        return None

    async def _extract_carrier(self, page: Page) -> str | None:
        loc = page.locator("span.carrier-name, span.logistics-name").first
        try:
            if await loc.count():
                return (await loc.inner_text(timeout=1500)).strip()
        except PWTimeout:
            pass
        return None
