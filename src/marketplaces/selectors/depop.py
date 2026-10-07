"""Depop selectors. React app, aggressive bot detection — go slow."""
from __future__ import annotations

SOLD_ITEMS_URL = "https://www.depop.com/{handle}/sold/"
SOLD_ITEM_CARD = "li[data-testid='sold-item'], a[data-testid*='sold-item']"
SOLD_ITEM_LINK = "a[href*='/products/']"
SOLD_ITEM_PRICE = "p[aria-label*='price'], span[data-testid='price']"
SOLD_ITEM_SALE_ID_ATTR = "data-sale-id"

SALE_DETAIL_URL = "https://www.depop.com/receipts/{sale_id}/"
SALE_BUYER_HANDLE = "a[data-testid='buyer-handle']"
SALE_SHIPPING_SECTION = "section[data-testid='shipping-address']"
SALE_ADDRESS_LINES = "p[data-testid='address-line']"
SALE_TRACKING_INPUT = "input[name='trackingNumber'], input[data-testid='tracking-input']"
SALE_CARRIER_SELECT = "select[name='carrier']"
SALE_SAVE_TRACKING = "button[data-testid='save-tracking']"

DM_INBOX_URL = "https://www.depop.com/messages/"
DM_THREAD_CARD = "li[data-testid='message-thread']"
DM_UNREAD_INDICATOR = "span[data-testid='unread-dot']"
DM_THREAD_BUYER = "span[data-testid='thread-user']"
DM_MESSAGES_LIST = "div[data-testid='message-bubble']"
DM_MESSAGE_INPUT = "textarea[placeholder*='Send a message'], textarea[name='messageBody']"
DM_SEND_BUTTON = "button[data-testid='send-message']"

LISTING_EDIT_URL = "https://www.depop.com/products/{listing_id}/edit/"
LISTING_PRICE_INPUT = "input[name='price'], input[data-testid='price']"
LISTING_SAVE_BUTTON = "button[data-testid='listing-save']"

BOT_CHECK_MARKERS = ["div[data-testid='bot-detection']", "iframe[src*='hcaptcha']"]
