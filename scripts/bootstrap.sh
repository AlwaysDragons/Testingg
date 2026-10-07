#!/usr/bin/env bash
# One-shot setup: generate .env from template with random secrets, prepare dirs.
#
# Usage: bash scripts/bootstrap.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  echo ".env already exists — leaving it alone."
else
  PGPW=$(openssl rand -hex 16 2>/dev/null || head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
  cp .env.example .env
  sed -i.bak \
    -e "s|POSTGRES_PASSWORD=CHANGE_ME|POSTGRES_PASSWORD=${PGPW}|" \
    -e "s|ds:CHANGE_ME@|ds:${PGPW}@|g" \
    .env
  rm -f .env.bak
  echo "✓ .env created with a generated Postgres password."
fi

mkdir -p data/sessions/depop data/sessions/grailed data/sessions/mercari
mkdir -p data/photos/raw data/photos/processed data/photos/backgrounds
mkdir -p data/dispute_packets

echo
echo "Next steps:"
echo "  1. Edit .env — set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID (minimum)"
echo "       Create a bot via @BotFather on Telegram → paste token here."
echo "       DM the bot once, then open https://api.telegram.org/bot<TOKEN>/getUpdates"
echo "       to find your chat.id."
echo "  2. docker compose build"
echo "  3. docker compose up -d"
echo "  4. docker compose logs -f telegram        # should say 'telegram bot online'"
echo "  5. In Telegram, send /health              # expect db ✓ redis ✓"
echo "  6. docker compose run --rm worker python -m scripts.seed_demo"
echo "       (seeds one demo SKU so /digest + /post have something to show)"
echo
echo "Proxies are OPTIONAL. Leave PROXY_HOST empty in .env and the VPS's own IP"
echo "is used. Add BrightData creds later when you want residential rotation."
