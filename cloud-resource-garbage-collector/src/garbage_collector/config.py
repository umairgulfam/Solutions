from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="CRGC_", env_file=".env", extra="ignore")

    database_url: str = "sqlite:///./garbage_collector.db"
    log_level: str = "INFO"
    api_key: str = "change-me"
    enable_deletion: bool = False
    approval_ttl_hours: int = 72
    idle_days: int = 30
    old_snapshot_days: int = 90
    old_image_days: int = 90
    min_monthly_cost: float = 1.0


@lru_cache
def get_settings() -> Settings:
    return Settings()
