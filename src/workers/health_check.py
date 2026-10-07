from loguru import logger


def run(*args, **kwargs) -> None:
    logger.info("worker health_check.run — Phase 0 stub")


def run_daily(*args, **kwargs) -> None:
    logger.info("worker health_check.run_daily — Phase 0 stub")
