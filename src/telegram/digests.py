"""Daily digest: top opportunities + yesterday's P&L summary."""
from __future__ import annotations

import asyncio
import datetime as dt

import httpx
from loguru import logger
from sqlalchemy import select

from src.config import settings
from src.db.models import PnlDaily
from src.db.session import session_scope
from src.ranker.opportunity import top_opportunities


async def _format_digest(limit: int = 10) -> str:
    opps = await top_opportunities(limit=limit)
    yesterday = dt.date.today() - dt.timedelta(days=1)
    async with session_scope() as sess:
        pnl = (
            await sess.execute(select(PnlDaily).where(PnlDaily.date == yesterday))
        ).scalar_one_or_none()

    lines = [
        f"daily digest — {dt.date.today().isoformat()}",
        "",
    ]
    if pnl:
        lines.append(
            f"yesterday: sales {pnl.sales_count or 0} · "
            f"gross ${pnl.gross_sales_usd or 0:.2f} · "
            f"net ${pnl.net_profit_usd or 0:.2f}"
        )
    else:
        lines.append("yesterday: no P&L row yet")
    lines.append("")

    if not opps:
        lines.append("no opportunities scored yet — seed catalog + market_listings first")
    else:
        lines.append(f"top {len(opps)} opportunities:")
        for i, o in enumerate(opps, 1):
            lines.append(
                f"  {i}. {o.sku} · median ${o.market_price_median or 0:.2f} · "
                f"cost ${o.supplier_cost_usd or 0:.2f} · "
                f"margin ${o.margin_usd or 0:.2f} · "
                f"vel {o.velocity_score or 0} · "
                f"sat {o.saturation_count or 0} · "
                f"score {o.composite_score or 0} · {o.recommended_action}"
            )
    return "\n".join(lines)


async def _post_async(body: str) -> None:
    token = settings.telegram_bot_token
    chat_id = settings.telegram_chat_id
    if not token or not chat_id:
        logger.warning("telegram token/chat not configured; digest not sent")
        return
    async with httpx.AsyncClient(timeout=15.0) as client:
        await client.post(
            f"https://api.telegram.org/bot{token}/sendMessage",
            json={"chat_id": chat_id, "text": body[:4000]},
        )


def send_daily_digest(*_args, **_kwargs) -> None:
    async def _wrap() -> None:
        body = await _format_digest()
        await _post_async(body)
        logger.info("daily digest posted ({} chars)", len(body))

    asyncio.run(_wrap())
