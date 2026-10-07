"""Keyword-driven intent classifier for inbound DMs.

Intents are checked in priority order — 'escalation' outranks everything so
anything smelling of return / refund / legal escalates to a human instead of
auto-reply. 'other' is the catch-all.
"""
from __future__ import annotations

import re

INTENTS: dict[str, list[str]] = {
    "escalation": [
        "refund", "return", "chargeback", "fraud", "scam",
        "wrong item", "broken", "damaged", "defective",
        "legal", "attorney", "lawyer", "report", "sue",
    ],
    "condition": ["condition", "worn", "wear", "flaws", "damage", "stain"],
    "shipping": [
        "ship", "shipping", "arrive", "arrival", "when", "tracking",
        "delivery", "fast", "express", "how long",
    ],
    "size": ["fit", "size", "measurements", "measure", "small", "large", "tts", "runs"],
    "offer": ["offer", "lower", "price", "discount", "deal", "best", "any room"],
    "product_info": ["material", "detail", "specs", "description", "info", "authentic", "legit"],
}


_PATTERNS = {
    intent: re.compile(r"(?i)\b(" + "|".join(re.escape(k) for k in kws) + r")\b")
    for intent, kws in INTENTS.items()
}

PRIORITY = ["escalation", "offer", "shipping", "size", "condition", "product_info"]


def classify(body: str) -> str:
    if not body:
        return "other"
    for intent in PRIORITY:
        if _PATTERNS[intent].search(body):
            return intent
    return "other"
