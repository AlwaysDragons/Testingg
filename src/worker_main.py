from loguru import logger
from rq import Worker

from src.config import settings
from src.queue import QUEUES, get_queue, get_redis
from src.utils.logging import configure_logging


def main() -> None:
    configure_logging()
    logger.info("RQ listening on: {}", ", ".join(QUEUES))
    conn = get_redis()
    queues = [get_queue(n) for n in QUEUES]
    worker = Worker(queues, connection=conn, name=f"ds-worker-{settings.env}")
    worker.work(with_scheduler=False)


if __name__ == "__main__":
    main()
