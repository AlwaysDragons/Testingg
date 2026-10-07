import asyncio
import sys
from typing import Any

import httpx
from loguru import logger

from src.config import settings


def _telegram_sink(message: Any) -> None:
    record = message.record
    if record["level"].no < logger.level("ERROR").no:
        return
    token = settings.telegram_bot_token
    chat_id = settings.telegram_chat_id
    if not token or not chat_id:
        return
    text = f"[{record['level'].name}] {record['name']}:{record['function']} — {record['message']}"
    try:
        asyncio.get_event_loop()
        asyncio.create_task(_post_telegram(token, chat_id, text))
    except RuntimeError:
        try:
            httpx.post(
                f"https://api.telegram.org/bot{token}/sendMessage",
                json={"chat_id": chat_id, "text": text[:4000]},
                timeout=5.0,
            )
        except Exception:
            pass


async def _post_telegram(token: str, chat_id: str, text: str) -> None:
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            await client.post(
                f"https://api.telegram.org/bot{token}/sendMessage",
                json={"chat_id": chat_id, "text": text[:4000]},
            )
    except Exception:
        pass


def configure_logging() -> None:
    logger.remove()
    logger.add(
        sys.stderr,
        level=settings.log_level,
        format="<green>{time:YYYY-MM-DD HH:mm:ss.SSS}</green> | "
        "<level>{level: <8}</level> | "
        "<cyan>{name}</cyan>:<cyan>{function}</cyan>:<cyan>{line}</cyan> | "
        "<level>{message}</level>",
    )
    logger.add(_telegram_sink, level="ERROR")


configure_logging()
