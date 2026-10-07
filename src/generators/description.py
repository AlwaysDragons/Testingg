"""Rotating description generator.

Four template bodies combined with four closers = 16 variants. Templates seeded
by (sku, size, posting_account) so re-posting the same SKU on another account
pulls a different combination. Tag block appended for Depop/Mercari search.
"""
from __future__ import annotations

import hashlib
import random

BODIES = [
    """{name} {variant}
Size: {size}
Condition: {condition}

{bullet_block}
""",
    """🔖 {name} — {variant}
📏 Size {size}
✨ {condition}

{bullet_block}
""",
    """{name} {variant}, size {size}.
Condition: {condition}.

{bullet_block}
""",
    """— {name} —
{variant} · size {size}
condition: {condition}

{bullet_block}
""",
]

BULLETS = [
    [
        "✓ Fast shipping, usually ships within 1-2 business days",
        "✓ Tracking shared as soon as package goes out",
        "✓ Open to reasonable offers",
        "✓ Smoke-free home",
    ],
    [
        "- 1-2 day handling",
        "- Tracking provided",
        "- Serious offers welcome",
        "- Carefully packed",
    ],
    [
        "• Ships within 48h",
        "• USPS tracking included",
        "• Make an offer",
        "• From a smoke-free home",
    ],
    [
        "→ Quick dispatch",
        "→ Tracking posted",
        "→ Offers via DM",
        "→ Thanks for looking!",
    ],
]

CLOSERS = [
    "DM with any questions. Thanks for stopping by!",
    "Message me if you want more photos or measurements.",
    "Check my other listings — bundle for a discount.",
    "Happy to answer any Qs — just drop a message.",
]


def _seed(sku: str, size: str, salt: str) -> int:
    return int.from_bytes(
        hashlib.sha1(f"{sku}:{size}:{salt}:desc".encode()).digest()[:8], "big"
    )


def generate_description(
    *,
    display_name: str,
    variant_group: str | None,
    size: str,
    condition: str,
    sku: str,
    salt: str,
    tags: list[str] | None = None,
) -> str:
    rnd = random.Random(_seed(sku, size, salt))
    body = rnd.choice(BODIES)
    bullets = rnd.choice(BULLETS)
    closer = rnd.choice(CLOSERS)
    text = body.format(
        name=display_name,
        variant=variant_group or "",
        size=size,
        condition=condition,
        bullet_block="\n".join(bullets),
    ).strip()
    text += "\n\n" + closer
    if tags:
        text += "\n\n" + " ".join(f"#{t.replace(' ', '')}" for t in tags[:12])
    return text
