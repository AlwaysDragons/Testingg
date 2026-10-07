"""Marketplace title generator.

Pattern:  "{brand/display_name} {variant} — {size} · {condition}"
Rotation seeds the template per listing so account rotation never produces
identical titles for the same SKU. Variant tokens pulled from the SKU's
product_catalog row + listing's size.
"""
from __future__ import annotations

import hashlib
import random

TEMPLATES = [
    "{name} {variant} — size {size} ({condition})",
    "{name} · {variant} · {size} / {condition}",
    "{name} {variant} ({size}) — {condition}",
    "{condition} {name} {variant} · size {size}",
    "{name} — {variant} / {size} / {condition}",
]

CONDITIONS = ["new w/ tags", "new w/o tags", "like new", "deadstock"]


def _seed(sku: str, size: str, salt: str) -> int:
    h = hashlib.sha1(f"{sku}:{size}:{salt}".encode()).digest()
    return int.from_bytes(h[:8], "big")


def generate_title(
    *,
    display_name: str,
    variant_group: str | None,
    size: str,
    condition: str | None,
    sku: str,
    salt: str,
    max_len: int = 80,
) -> str:
    rnd = random.Random(_seed(sku, size, salt))
    tmpl = rnd.choice(TEMPLATES)
    cond = condition or rnd.choice(CONDITIONS)
    out = tmpl.format(
        name=display_name,
        variant=variant_group or "",
        size=size,
        condition=cond,
    ).replace("  ", " ").strip(" ·—/")
    if len(out) > max_len:
        out = out[: max_len - 1].rstrip() + "…"
    return out
