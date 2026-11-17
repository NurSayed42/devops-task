"""Application configuration, read entirely from environment variables."""

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    port: int
    log_level: str
    environment: str
    app_version: str


def get_settings() -> Settings:
    return Settings(
        port=int(os.getenv("PORT", "8080")),
        log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
        environment=os.getenv("APP_ENV", "development"),
        app_version=os.getenv("APP_VERSION", "0.1.0"),
    )
