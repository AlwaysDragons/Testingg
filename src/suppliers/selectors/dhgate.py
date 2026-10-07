"""DHgate product + checkout selectors.

DHgate has a stable DOM for the product + checkout flow despite being pre-React.
When they change, edit this file only — nothing in src/suppliers/dhgate.py
hardcodes a selector string.
"""
from __future__ import annotations

PRODUCT_PRICE_PRIMARY = "span.price-cur, span.product-info-price, span.p-price-now"
PRODUCT_PRICE_FALLBACK = "[class*='price'] .num, [class*='price-current']"
PRODUCT_COLOR_BUTTON = "div.product-sku ul li[title='{color}'], ul.sku-item li[title='{color}']"
PRODUCT_SIZE_SELECT = "select#size-select, select[name='size']"
PRODUCT_SIZE_OPTION = "option:has-text('{size}')"
PRODUCT_QTY_INPUT = "input#productQuantity, input.quantity-input"
PRODUCT_BUY_NOW = "a#buyNow, button#buy-now, a:has-text('Buy Now')"

CHECKOUT_SHIPPING_ADDRESS_FORM = "form[name='shippingAddress'], div.shipping-address-form"
CHECKOUT_ADDRESS_RECIPIENT = "input[name='firstName'], input[name='consigneeName']"
CHECKOUT_ADDRESS_LINE1 = "input[name='street'], input[name='address1']"
CHECKOUT_ADDRESS_LINE2 = "input[name='street2'], input[name='address2']"
CHECKOUT_ADDRESS_CITY = "input[name='city']"
CHECKOUT_ADDRESS_STATE = "select[name='state'], select[name='province']"
CHECKOUT_ADDRESS_POSTAL = "input[name='postCode'], input[name='zipCode']"
CHECKOUT_ADDRESS_COUNTRY = "select[name='country']"
CHECKOUT_ADDRESS_PHONE = "input[name='phone'], input[name='mobile']"
CHECKOUT_ADDRESS_SAVE = "button:has-text('Save'), button.save-address"

CHECKOUT_SHIPPING_METHOD_RADIO = "input[type='radio'][name*='shipping']"
CHECKOUT_SHIPPING_METHOD_LABEL = "label[for='{radio_id}']"

CHECKOUT_MESSAGE_TEXTAREA = "textarea[name='leaveMessage'], textarea.leave-message"
CHECKOUT_PAY_BUTTON = "button#submitOrder, button:has-text('Place Order')"
CHECKOUT_PAY_CONFIRM = "button:has-text('Confirm Payment'), button.pay-confirm"

ORDER_CONFIRMATION_REF = "span.order-no, span.order-number, [class*='order-id']"
PRICE_FINAL = "span.total-price, span.order-total, span.payment-amount"

CAPTCHA_MARKERS = [
    "iframe[src*='recaptcha']",
    "iframe[src*='captcha']",
    "div.geetest_panel",
    "div#nc_1_wrapper",
]

STOCK_OUT_MARKER = ":has-text('Out of stock'), :has-text('Sold out')"
