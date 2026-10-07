"""Grailed selectors."""
from __future__ import annotations

SOLD_URL = "https://www.grailed.com/sales"
SOLD_ROW = "tr.Transaction, div[class*='Sale__row']"
SOLD_SALE_ID_ATTR = "data-sale-id"
SOLD_LISTING_ID_ATTR = "data-listing-id"
SOLD_BUYER = "a[class*='buyer'], span.buyer-handle"
SOLD_PRICE = "span.price, td.price"

SALE_DETAIL_URL = "https://www.grailed.com/sales/{sale_id}"
BUYER_ADDRESS_SECTION = "section.shipping-address, div[class*='ShippingAddress']"
ADDRESS_LINES = "p.address-line, li.address-line"
TRACKING_INPUT = "input[name='tracking_number']"
CARRIER_INPUT = "input[name='carrier']"
TRACKING_SAVE = "button:has-text('Save tracking'), button:has-text('Mark shipped')"

DM_INBOX_URL = "https://www.grailed.com/messages"
DM_THREAD_CARD = "div[class*='ConversationListItem']"
DM_UNREAD = "div[class*='unread']"
DM_THREAD_BUYER = "span.conversation-user"
DM_MESSAGES_LIST = "div[class*='MessageBubble']"
DM_INPUT = "textarea[name='message'], textarea[placeholder*='Message']"
DM_SEND = "button:has-text('Send')"

LISTING_EDIT_URL = "https://www.grailed.com/listings/{listing_id}/edit"
LISTING_PRICE_INPUT = "input[name='price']"
LISTING_SAVE = "button:has-text('Save')"

BOT_MARKERS = ["div.px-captcha", "iframe[src*='perimeterx']"]
