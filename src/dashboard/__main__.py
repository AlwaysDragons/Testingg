"""uvicorn entrypoint for the dashboard."""
from __future__ import annotations

import os

import uvicorn

from src.utils.logging import configure_logging


def main() -> None:
    configure_logging()
    uvicorn.run(
        "src.dashboard.app:app",
        host="0.0.0.0",
        port=int(os.environ.get("DASHBOARD_PORT", "8787")),
        log_level="info",
    )


if __name__ == "__main__":
    main()
