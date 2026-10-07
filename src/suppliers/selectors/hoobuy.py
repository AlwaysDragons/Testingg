"""Hoobuy agent selectors — add-to-cart flow with QC gate."""
from __future__ import annotations

PRODUCT_PRICE = "span.price, .product-price, [class*='goods-price']"
PRODUCT_URL_INPUT = "input#product-link, input[placeholder*='link']"
PARSE_LINK_BUTTON = "button:has-text('Parse'), button:has-text('Submit')"
VARIANT_COLOR = "div.sku-color [data-value='{color}']"
VARIANT_SIZE = "div.sku-size [data-value='{size}']"
QTY_INPUT = "input[name='quantity']"
ADD_TO_CART = "button:has-text('Add to cart'), button:has-text('Buy now')"
CART_CHECKOUT = "button:has-text('Checkout')"

ADDRESS_RECIPIENT = "input[name='consignee']"
ADDRESS_LINE1 = "input[name='address']"
ADDRESS_CITY = "input[name='city']"
ADDRESS_STATE = "input[name='state']"
ADDRESS_POSTAL = "input[name='zip']"
ADDRESS_COUNTRY = "select[name='country']"
ADDRESS_PHONE = "input[name='phone']"
REMARK_TEXTAREA = "textarea[name='remark'], textarea.order-remark"

CONFIRM_ORDER = "button:has-text('Submit order'), button:has-text('Pay')"
PAY_WITH_BALANCE = "label:has-text('Balance'), input[value='balance']"
ORDER_REF = "span.order-sn, [class*='order-number']"

QC_PHOTOS_LINK = "a:has-text('QC photos'), a:has-text('Quality check')"
QC_APPROVE_BUTTON = "button:has-text('Approve'), button:has-text('Ship it')"
QC_REJECT_BUTTON = "button:has-text('Reject'), button:has-text('Return')"
