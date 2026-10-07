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
mkdir -p data/dispute_packets data/logs

echo
echo "Next steps:"
echo "  1. make build"
echo "  2. make up"
echo "  3. Open http://localhost:8787  — the dashboard"
echo "       Go to the Settings tab and paste your Telegram bot token + chat id."
echo "       Press SAVE, then run:  docker compose restart telegram"
echo "  4. make seed    # drops in one demo SKU so views have data"
echo
echo "Proxies are OPTIONAL. Leave PROXY_HOST blank — the stack runs direct"
echo "from this machine. Add BrightData later only if you scale beyond 3 accounts/platform."
