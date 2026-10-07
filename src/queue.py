from redis import Redis
from rq import Queue

from src.config import settings

QUEUES = [
    "poll_sold",
    "fulfill_order",
    "tracking",
    "scraping",
    "listing_posts",
    "dm_responses",
    "repricing",
    "review_solicit",
    "competitor_watch",
    "pnl_rollup",
    "warm_account",
    "health_checks",
]


def get_redis() -> Redis:
    return Redis.from_url(settings.redis_url)


def get_queue(name: str) -> Queue:
    if name not in QUEUES:
        raise ValueError(f"unknown queue: {name}")
    return Queue(name, connection=get_redis())
