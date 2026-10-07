"""Template library for DM auto-responses.

Each intent has 3-5 rotating variants seeded by (platform, buyer_handle) so
replies feel human and different accounts don't share a fingerprint.
"""
from __future__ import annotations

import hashlib
import random

TEMPLATES: dict[str, list[str]] = {
    "shipping": [
        "Hey! Ships within 1-2 business days, delivery usually 7-14 days depending on your location. Will share tracking as soon as it goes out.",
        "Hi! Processing time 1-2 days, then 1-2 weeks to arrive. Tracking will be posted here once shipped.",
        "Thanks for the message — orders go out within 48h, delivery typically runs 1-2 weeks. Tracking will land in your inbox when it's shipped.",
    ],
    "size": [
        "The listed size is standard — fits true-to-size for most people. Happy to grab measurements if you share your usual size.",
        "Runs true to size based on past buyers' feedback. Let me know your usual fit if you want me to double-check.",
        "Standard fit as marked. I can take measurements if you let me know what you usually wear.",
    ],
    "offer": [
        "Appreciate the offer — I can do a small discount if you want to go through my offer button. Thanks!",
        "Thanks for reaching out — the price is a bit firm but feel free to send an offer and I'll see what I can do.",
        "I can work with you a little — send a reasonable offer and I'll take a look.",
    ],
    "condition": [
        "Condition is as listed — I've gone over it carefully. Happy to send more detailed photos of any specific area if you want.",
        "In the condition described in the listing. If there's a specific spot you want me to photograph closer, just say.",
        "Matches the condition on the listing. Let me know if you want zoom-in photos of anything specific.",
    ],
    "product_info": [
        "All the details I have are in the description — let me know what specifically you want to know and I'll check.",
        "Everything I know is in the listing — ask about any specific detail and I'll dig for it.",
        "Full info in the listing. If something's not covered there, just ask and I'll check.",
    ],
}


def pick_template(intent: str, platform: str, buyer_handle: str) -> str | None:
    pool = TEMPLATES.get(intent)
    if not pool:
        return None
    seed = int.from_bytes(
        hashlib.sha1(f"{platform}:{buyer_handle}:{intent}".encode()).digest()[:8], "big"
    )
    return random.Random(seed).choice(pool)
