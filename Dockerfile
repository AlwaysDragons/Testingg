FROM mcr.microsoft.com/playwright/python:v1.47.0-jammy

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# System deps: tesseract for OCR on dispute proofs, libpq for psycopg2.
RUN apt-get update && apt-get install -y --no-install-recommends \
        tesseract-ocr \
        libpq-dev \
        gcc \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Python deps resolved first so repeat builds hit the layer cache.
COPY pyproject.toml ./
RUN pip install --upgrade pip setuptools wheel \
    && pip install . \
    && python -c "import setuptools, loguru, sqlalchemy, pydantic_settings; print('deps ok')"

# App code last — one layer bust on every commit.
COPY . .

# Data dirs so volume mounts don't fail on first boot.
RUN mkdir -p /data/sessions/depop /data/sessions/grailed /data/sessions/mercari \
             /data/photos/raw /data/photos/processed /data/photos/backgrounds \
             /data/dispute_packets

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "from src.config import settings; print(settings.env)" || exit 1

CMD ["python", "-m", "src.scheduler_main"]
