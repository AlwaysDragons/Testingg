"""Mercari selectors."""
from __future__ import annotations

SOLD_URL = "https://www.mercari.com/mypage/sold/"
SOLD_CARD = "li[data-testid='sold-item'], div[class*='sold-item']"
SOLD_LISTING_ID_ATTR = "data-item-id"
SOLD_SALE_ID_ATTR = "data-transaction-id"
SOLD_BUYER = "a[data-testid='buyer-link']"
SOLD_PRICE = "span[data-testid='price']"

SALE_DETAIL_URL = "https://www.mercari.com/transaction/{sale_id}/"
BUYER_ADDRESS_SECTION = "section[data-testid='shipping-info']"
ADDRESS_LINES = "p[data-testid='address-line']"
TRACKING_INPUT = "input[name='trackingNumber']"
CARRIER_SELECT = "select[name='carrier']"
TRACKING_SAVE = "button[data-testid='save-tracking']"

DM_INBOX_URL = "https://www.mercari.com/messages/"
DM_THREAD_CARD = "li[data-testid='message-thread']"
DM_UNREAD = "span[data-testid='unread-marker']"
DM_BUYER = "span[data-testid='other-user']"
DM_MESSAGES = "div[data-testid='message-text']"
DM_INPUT = "textarea[data-testid='message-input']"
DM_SEND = "button[data-testid='send-message']"

LISTING_EDIT_URL = "https://www.mercari.com/sell/edit/{listing_id}/"
LISTING_PRICE_INPUT = "input[name='price']"
LISTING_SAVE = "button[data-testid='listing-save']"

BOT_MARKERS = ["div.px-captcha", "iframe[src*='datadome']"]
