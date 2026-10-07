"""Pre-stocked inventory tracker + reshipper fulfillment entrypoint.

Phase 3 stub — real implementation lands in Phase 7 alongside the Shipito
API client. Keeps fulfill_order's prestocked branch resolvable.
"""
from __future__ import annotations

from loguru import logger


async def fulfill_from_reshipper(order_id: int, sale) -> None:  # noqa: ARG001
    logger.info("fulfill_from_reshipper({}) — Phase 7 stub, not implemented", order_id)
    raise NotImplementedError("reshipper fulfillment arrives in Phase 7")
