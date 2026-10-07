from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass

from src.db.models import PostingAccount


@dataclass
class PostResult:
    ok: bool
    platform_listing_id: str | None = None
    url: str | None = None
    error: str | None = None


class PosterBase(ABC):
    name: str = "base"

    @abstractmethod
    async def create_listing(
        self,
        account: PostingAccount,
        *,
        title: str,
        description: str,
        price_usd: float,
        size: str,
        category: str,
        photos: list[str],
        tags: list[str] | None = None,
    ) -> PostResult: ...
