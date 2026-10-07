import signal

from apscheduler.schedulers.blocking import BlockingScheduler
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.interval import IntervalTrigger
from loguru import logger

from src.config import settings
from src.queue import get_queue
from src.utils.logging import configure_logging


def _enqueue(queue: str, func_path: str) -> None:
    try:
        get_queue(queue).enqueue(func_path)
        logger.debug("enqueued {} -> {}", func_path, queue)
    except Exception as exc:
        logger.exception("enqueue failed: {} ({})", func_path, exc)


def register_jobs(sched: BlockingScheduler) -> None:
    sched.add_job(
        _enqueue,
        IntervalTrigger(minutes=settings.poll_sold_interval_minutes),
        args=["poll_sold", "src.workers.poll_sold.run"],
        id="poll_sold",
        replace_existing=True,
    )
    sched.add_job(
        _enqueue,
        IntervalTrigger(minutes=settings.tracking_poll_interval_minutes),
        args=["tracking", "src.workers.tracking.run"],
        id="tracking",
        replace_existing=True,
    )
    sched.add_job(
        _enqueue,
        IntervalTrigger(hours=settings.scrape_interval_hours),
        args=["scraping", "src.workers.market_scrape.run"],
        id="market_scrape",
        replace_existing=True,
    )
    sched.add_job(
        _enqueue,
        IntervalTrigger(hours=settings.health_check_interval_hours),
        args=["health_checks", "src.workers.health_check.run"],
        id="health_check",
        replace_existing=True,
    )
    sched.add_job(
        _enqueue,
        IntervalTrigger(hours=settings.reprice_interval_hours),
        args=["repricing", "src.workers.reprice.run"],
        id="reprice",
        replace_existing=True,
    )
    sched.add_job(
        _enqueue,
        IntervalTrigger(hours=settings.competitor_watch_interval_hours),
        args=["competitor_watch", "src.workers.competitor_watch.run"],
        id="competitor_watch",
        replace_existing=True,
    )
    sched.add_job(
        _enqueue,
        IntervalTrigger(minutes=settings.dm_poll_interval_minutes),
        args=["dm_responses", "src.workers.dm_responder.run"],
        id="dm_poll",
        replace_existing=True,
    )
    sched.add_job(
        _enqueue,
        CronTrigger(hour=settings.daily_digest_hour, minute=0),
        args=["pnl_rollup", "src.workers.pnl_rollup.run"],
        id="pnl_daily",
        replace_existing=True,
    )
    sched.add_job(
        _enqueue,
        CronTrigger(hour=settings.daily_digest_hour, minute=5),
        args=["pnl_rollup", "src.telegram.digests.send_daily_digest"],
        id="daily_digest",
        replace_existing=True,
    )
    sched.add_job(
        _enqueue,
        CronTrigger(hour=0, minute=0),
        args=["warm_account", "src.workers.warm_account.run_daily"],
        id="warm_cycle",
        replace_existing=True,
    )
    sched.add_job(
        _enqueue,
        CronTrigger(hour="*", minute=30),
        args=["review_solicit", "src.workers.review_solicit.run"],
        id="review_solicit",
        replace_existing=True,
    )


def main() -> None:
    configure_logging()
    sched = BlockingScheduler(timezone=settings.tz)
    register_jobs(sched)
    logger.info("APScheduler started, {} jobs registered", len(sched.get_jobs()))

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: sched.shutdown(wait=False))

    sched.start()


if __name__ == "__main__":
    main()
