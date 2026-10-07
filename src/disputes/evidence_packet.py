"""Compose a PDF evidence packet for a sale under dispute.

Pulls:
  - sales row, our_listings row, posting_account
  - supplier_orders row (tracking, carrier, cost)
  - dm_threads + dm_messages chronological

Writes to /data/dispute_packets/<sale_id>.pdf. The path is written back onto
the disputes row so Telegram can re-fetch and resend. Buyer PII minimized
in the packet (recipient name + city/state only; street is implied by
tracking).
"""
from __future__ import annotations

import asyncio
import datetime as dt
from pathlib import Path

from loguru import logger
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table
from sqlalchemy import select

from src.db.models import (
    DmMessage,
    DmThread,
    Dispute,
    OurListing,
    PostingAccount,
    Sale,
    SupplierOrder,
)
from src.db.session import session_scope


async def _bundle(sale_id: int) -> dict:
    async with session_scope() as sess:
        sale = (await sess.execute(select(Sale).where(Sale.id == sale_id))).scalar_one_or_none()
        if sale is None:
            return {}
        listing = (
            await sess.execute(select(OurListing).where(OurListing.id == sale.our_listing_id))
        ).scalar_one_or_none()
        account = (
            await sess.execute(
                select(PostingAccount).where(PostingAccount.id == (listing.posting_account_id if listing else None))
            )
        ).scalar_one_or_none() if listing else None
        order = (
            await sess.execute(select(SupplierOrder).where(SupplierOrder.sale_id == sale.id))
        ).scalar_one_or_none()
        thread = (
            await sess.execute(
                select(DmThread).where(DmThread.buyer_handle == sale.buyer_handle)
            )
        ).scalar_one_or_none()
        messages = (
            (await sess.execute(
                select(DmMessage).where(DmMessage.thread_id == thread.id).order_by(DmMessage.sent_at.asc())
            )).scalars().all()
            if thread else []
        )
    return {
        "sale": sale,
        "listing": listing,
        "account": account,
        "order": order,
        "messages": messages,
    }


def _render(bundle: dict, out_path: Path) -> None:
    styles = getSampleStyleSheet()
    doc = SimpleDocTemplate(str(out_path), pagesize=LETTER, title=f"evidence-{bundle['sale'].id}")
    story = []
    sale = bundle["sale"]
    listing = bundle.get("listing")
    account = bundle.get("account")
    order = bundle.get("order")

    story.append(Paragraph(f"<b>Evidence packet — sale #{sale.id}</b>", styles["Title"]))
    story.append(Paragraph(f"Generated {dt.datetime.utcnow().isoformat()}Z", styles["Normal"]))
    story.append(Spacer(1, 0.2 * inch))

    story.append(Paragraph("<b>Transaction</b>", styles["Heading2"]))
    buyer_city = (sale.buyer_address or {}).get("city", "—")
    buyer_state = (sale.buyer_address or {}).get("state", "—")
    tx_rows = [
        ["Platform", sale.platform],
        ["Platform sale id", sale.platform_sale_id],
        ["Sold at", str(sale.sold_at)],
        ["Buyer", f"{sale.buyer_handle or '—'} ({buyer_city}, {buyer_state})"],
        ["Gross", f"${sale.sale_price_usd or '—'}"],
        ["Platform fee", f"${sale.platform_fee_usd or '—'}"],
    ]
    story.append(Table(tx_rows, colWidths=[1.6 * inch, 4.4 * inch]))
    story.append(Spacer(1, 0.2 * inch))

    story.append(Paragraph("<b>Listing</b>", styles["Heading2"]))
    if listing:
        rows = [
            ["Title", listing.title or "—"],
            ["URL", listing.url or "—"],
            ["Price listed", f"${listing.price_usd or '—'}"],
            ["Posted at", str(listing.posted_at)],
            ["Account", account.handle if account else "—"],
        ]
        story.append(Table(rows, colWidths=[1.6 * inch, 4.4 * inch]))
        story.append(Spacer(1, 0.1 * inch))
        if listing.description:
            story.append(Paragraph(listing.description.replace("\n", "<br/>"), styles["Normal"]))
    else:
        story.append(Paragraph("Listing record not found.", styles["Normal"]))
    story.append(Spacer(1, 0.2 * inch))

    story.append(Paragraph("<b>Shipping / supplier order</b>", styles["Heading2"]))
    if order:
        rows = [
            ["Source", order.source or "—"],
            ["Supplier ref", order.supplier_order_ref or "—"],
            ["Tracking", order.tracking_number or "—"],
            ["Carrier", order.tracking_carrier or "—"],
            ["Status", order.status or "—"],
            ["Shipped at", str(order.shipped_at)],
            ["Delivered at", str(order.delivered_at)],
            ["Cost", f"${order.cost_usd or '—'}"],
        ]
        story.append(Table(rows, colWidths=[1.6 * inch, 4.4 * inch]))
    else:
        story.append(Paragraph("No supplier order on file.", styles["Normal"]))

    story.append(PageBreak())
    story.append(Paragraph("<b>Message history</b>", styles["Heading2"]))
    msgs = bundle.get("messages") or []
    if not msgs:
        story.append(Paragraph("No messages recorded.", styles["Normal"]))
    else:
        for m in msgs:
            direction = "Buyer" if m.direction == "in" else "Seller"
            story.append(
                Paragraph(
                    f"<b>{direction} · {m.sent_at:%Y-%m-%d %H:%M}</b><br/>{(m.body or '').replace(chr(10), '<br/>')}",
                    styles["Normal"],
                )
            )
            story.append(Spacer(1, 0.1 * inch))

    doc.build(story)


async def _record_dispute(sale_id: int, path: Path) -> None:
    from sqlalchemy.dialects.postgresql import insert as pg_insert

    async with session_scope() as sess:
        await sess.execute(
            pg_insert(Dispute.__table__).values(
                sale_id=sale_id,
                evidence_packet_path=str(path),
                opened_at=dt.datetime.now(tz=dt.timezone.utc),
                status="open",
            )
        )


async def build_packet(sale_id: int, out_dir: str = "/data/dispute_packets") -> Path | None:
    bundle = await _bundle(sale_id)
    if not bundle:
        logger.error("dispute packet: sale {} not found", sale_id)
        return None
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"{sale_id}.pdf"
    _render(bundle, path)
    await _record_dispute(sale_id, path)
    logger.info("dispute packet written: {}", path)
    return path


def run(sale_id: int) -> str | None:
    path = asyncio.run(build_packet(sale_id))
    return str(path) if path else None
