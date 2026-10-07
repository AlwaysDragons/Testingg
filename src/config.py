from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    env: str = "production"
    log_level: str = "INFO"
    tz: str = "America/Chicago"

    database_url: str
    database_url_sync: str
    redis_url: str = "redis://redis:6379/0"

    depop_session_dir: str = "/data/sessions/depop/"
    grailed_session_dir: str = "/data/sessions/grailed/"
    mercari_session_dir: str = "/data/sessions/mercari/"

    dhgate_session_file: str = "/data/sessions/dhgate.json"
    hoobuy_session_file: str = "/data/sessions/hoobuy.json"
    kakobuy_session_file: str = "/data/sessions/kakobuy.json"

    reshipper: str = "shipito"
    shipito_api_key: str = ""
    shipito_account_id: str = ""

    proxy_provider: str = "brightdata"
    proxy_host: str = ""
    proxy_port: int = 22225
    proxy_user: str = ""
    proxy_pass: str = ""
    proxy_slots: int = 5

    telegram_bot_token: str = ""
    telegram_chat_id: str = ""
    telegram_admin_ids: str = ""

    poll_sold_interval_minutes: int = 10
    scrape_interval_hours: int = 6
    health_check_interval_hours: int = 24
    tracking_poll_interval_minutes: int = 30
    reprice_interval_hours: int = 24
    competitor_watch_interval_hours: int = 4
    dm_poll_interval_minutes: int = 5
    review_solicit_delay_days: int = 3
    daily_digest_hour: int = 8

    max_listings_per_account_per_day: int = 5
    max_simultaneous_browsers: int = 3
    warming_period_days: int = 7
    warming_actions_per_day: int = 3
    price_breach_threshold_pct: int = 15
    reprice_floor_margin_pct: int = 60

    @property
    def admin_ids(self) -> list[int]:
        if not self.telegram_admin_ids:
            return []
        return [int(x.strip()) for x in self.telegram_admin_ids.split(",") if x.strip()]

    @property
    def repo_root(self) -> Path:
        return Path(__file__).resolve().parent.parent


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
