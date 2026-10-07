"""Shared helpers for marketplace drivers."""
from __future__ import annotations

import datetime as dt
import re
from decimal import Decimal, InvalidOperation
from typing import Any

PRICE_RE = re.compile(r"[\d]+\.?\d*")


def parse_price(text: str) -> Decimal | None:
    if not text:
        return None
    m = PRICE_RE.search(text)
    if not m:
        return None
    try:
        return Decimal(m.group(0))
    except InvalidOperation:
        return None


def address_lines_to_dict(lines: list[str]) -> dict[str, Any]:
    """Parse free-form US address lines into components."""
    lines = [ln.strip() for ln in lines if ln and ln.strip()]
    out: dict[str, Any] = {
        "recipient": lines[0] if lines else None,
        "line1": lines[1] if len(lines) > 1 else None,
        "line2": None,
        "city": None,
        "state": None,
        "postal_code": None,
        "country": "US",
    }
    # Last line is usually "City, ST 12345[-6789]" or "City, ST 12345, USA"
    for candidate in reversed(lines):
        m = re.search(r"([A-Za-z .'-]+),\s*([A-Z]{2})\s+(\d{5}(?:-\d{4})?)", candidate)
        if m:
            out["city"] = m.group(1).strip()
            out["state"] = m.group(2)
            out["postal_code"] = m.group(3)
            break
    # If we have 4+ lines, middle lines are extended street / apt
    if len(lines) >= 4 and out["city"]:
        middle = lines[2:-1]
        if middle:
            out["line2"] = " ".join(middle)
    if "USA" in (lines[-1] if lines else "").upper() or "UNITED STATES" in (lines[-1] if lines else "").upper():
        out["country"] = "US"
    return out


def utcnow() -> dt.datetime:
    return dt.datetime.now(tz=dt.timezone.utc)
