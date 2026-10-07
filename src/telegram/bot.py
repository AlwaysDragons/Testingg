from __future__ import annotations

from loguru import logger
from sqlalchemy import text
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes

from src.config import settings
from src.db.session import session_scope
from src.queue import get_redis
from src.utils.logging import configure_logging


def _is_admin(update: Update) -> bool:
    admins = set(settings.admin_ids)
    if not admins:
        return True
    user = update.effective_user
    return user is not None and user.id in admins


async def cmd_start(update: Update, _ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not _is_admin(update) or update.effective_chat is None:
        return
    await update.effective_chat.send_message(
        "dropship-mp online. commands: /health /digest /pnl /post /dispute"
    )


async def cmd_health(update: Update, _ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not _is_admin(update) or update.effective_chat is None:
        return
    db_ok = redis_ok = False
    db_detail = redis_detail = ""
    try:
        async with session_scope() as sess:
            await sess.execute(text("SELECT 1"))
        db_ok = True
    except Exception as exc:
        db_detail = str(exc)[:120]
    try:
        get_redis().ping()
        redis_ok = True
    except Exception as exc:
        redis_detail = str(exc)[:120]

    lines = [
        "health",
        f"  db:    {'✓' if db_ok else '✗ ' + db_detail}",
        f"  redis: {'✓' if redis_ok else '✗ ' + redis_detail}",
        f"  env:   {settings.env}",
    ]
    await update.effective_chat.send_message("\n".join(lines))


async def cmd_digest(update: Update, _ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not _is_admin(update) or update.effective_chat is None:
        return
    await update.effective_chat.send_message("digest — Phase 4 stub, no data yet")


async def cmd_pnl(update: Update, _ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not _is_admin(update) or update.effective_chat is None:
        return
    await update.effective_chat.send_message("pnl — Phase 6 stub")


async def cmd_post(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not _is_admin(update) or update.effective_chat is None:
        return
    if not ctx.args:
        await update.effective_chat.send_message(
            "usage: /post <SKU> [depop,grailed,mercari]"
        )
        return
    sku = ctx.args[0]
    platforms = (
        [p.strip() for p in ctx.args[1].split(",") if p.strip()]
        if len(ctx.args) > 1
        else None
    )
    await update.effective_chat.send_message(f"posting {sku}… (enqueued)")
    from src.queue import get_queue

    get_queue("listing_posts").enqueue(
        "src.workers.listing_post.run", sku, platforms, job_timeout=900
    )


async def cmd_dispute(update: Update, _ctx: ContextTypes.DEFAULT_TYPE) -> None:
    if not _is_admin(update) or update.effective_chat is None:
        return
    await update.effective_chat.send_message("dispute — Phase 7 stub")


def main() -> None:
    configure_logging()
    if not settings.telegram_bot_token:
        logger.error("TELEGRAM_BOT_TOKEN not set — telegram service refusing to start")
        raise SystemExit(1)

    app = Application.builder().token(settings.telegram_bot_token).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("health", cmd_health))
    app.add_handler(CommandHandler("digest", cmd_digest))
    app.add_handler(CommandHandler("pnl", cmd_pnl))
    app.add_handler(CommandHandler("post", cmd_post))
    app.add_handler(CommandHandler("dispute", cmd_dispute))

    logger.info("telegram bot online — polling")
    app.run_polling(allowed_updates=Update.ALL_TYPES, stop_signals=None)


if __name__ == "__main__":
    main()
