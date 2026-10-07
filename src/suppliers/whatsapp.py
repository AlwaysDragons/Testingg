"""WhatsApp bulk-order coordination for off-platform DHgate sellers.

Flow (how it's used, not what it does on its own): some high-score DHgate
sellers prefer taking orders over WhatsApp with a weekly batch invoice. The
agent compiles the week's queued orders for that seller, formats a plain-text
manifest, and sends it via Twilio's WhatsApp Business API. The seller replies
with a payment link + ETA. We log both sides against the supplier_orders row.

Requires Twilio credentials in env — if missing, this is a dry-run that
writes the manifest text to disk for manual send.
"""
from __future__ import annotations

import datetime as dt
import os
from pathlib import Path
from typing import Iterable

import httpx
from loguru import logger


class WhatsAppSender:
    def __init__(self) -> None:
        self.sid = os.environ.get("TWILIO_ACCOUNT_SID", "")
        self.token = os.environ.get("TWILIO_AUTH_TOKEN", "")
        self.from_ = os.environ.get("TWILIO_WHATSAPP_FROM", "")

    def configured(self) -> bool:
        return bool(self.sid and self.token and self.from_)

    async def send(self, to_whatsapp: str, body: str) -> bool:
        if not self.configured():
            path = Path("/data/dispute_packets") / f"whatsapp-draft-{int(dt.datetime.utcnow().timestamp())}.txt"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"TO: {to_whatsapp}\n\n{body}\n")
            logger.warning("twilio not configured — manifest saved to {}", path)
            return False
        url = f"https://api.twilio.com/2010-04-01/Accounts/{self.sid}/Messages.json"
        try:
            async with httpx.AsyncClient(timeout=20.0, auth=(self.sid, self.token)) as c:
                r = await c.post(
                    url,
                    data={
                        "From": f"whatsapp:{self.from_}",
                        "To": f"whatsapp:{to_whatsapp}",
                        "Body": body[:1500],
                    },
                )
            return r.status_code < 300
        except Exception as exc:
            logger.exception("whatsapp send: {}", exc)
            return False


def compose_manifest(seller_name: str, rows: Iterable[dict]) -> str:
    lines = [f"Bulk order manifest — {dt.date.today().isoformat()}", f"Seller: {seller_name}", ""]
    total = 0.0
    for i, r in enumerate(rows, 1):
        lines.append(
            f"{i}. {r.get('product_url')}  qty {r.get('qty', 1)}  "
            f"color {r.get('color', '-')}  size {r.get('size', '-')}  "
            f"ship-to {r.get('ship_to', '-')}"
        )
        total += float(r.get("expected_price_usd", 0.0)) * int(r.get("qty", 1))
    lines.append("")
    lines.append(f"Expected total: ${total:.2f}")
    lines.append("Please confirm receipt and share payment link + ETA.")
    return "\n".join(lines)
