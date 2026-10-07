from __future__ import annotations

from src.marketplaces.base import MarketplaceBase
from src.marketplaces.depop import Depop
from src.marketplaces.grailed import Grailed
from src.marketplaces.mercari import Mercari

_REGISTRY: dict[str, MarketplaceBase] = {
    "depop": Depop(),
    "grailed": Grailed(),
    "mercari": Mercari(),
}

PLATFORM_FEE_RATE: dict[str, float] = {
    "depop": 0.10,
    "grailed": 0.09,
    "mercari": 0.10,
}


def get_marketplace(name: str) -> MarketplaceBase:
    if name not in _REGISTRY:
        raise ValueError(f"unknown marketplace: {name}")
    return _REGISTRY[name]


def platform_fee(platform: str, gross: float) -> float:
    return round(gross * PLATFORM_FEE_RATE.get(platform, 0.10), 2)
