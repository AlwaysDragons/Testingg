# dropship-mp

Marketplace-native dropship automation across Depop, Grailed, Mercari.

## Phase 0 — foundation (current)

Scaffolded: repo layout, docker-compose, Dockerfile, Postgres schema (alembic migration), Redis + RQ queue registry, APScheduler job registry, Telegram bot with `/health`, worker stubs, config loader, Loguru + Telegram error sink.

## Boot

```bash
cp .env.example .env
# edit .env — set POSTGRES_PASSWORD, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
docker compose build
docker compose up -d
docker compose logs -f telegram
```

Then `/health` in Telegram → db ✓, redis ✓.

## Services

- `db` — Postgres 15
- `redis` — Redis 7 (RQ broker)
- `migrate` — runs `alembic upgrade head` on boot
- `scheduler` — APScheduler, enqueues jobs
- `worker` — RQ worker consuming all 12 queues
- `telegram` — bot (long-polling, no public endpoint)

## Build phases

- [x] Phase 0 — foundation
- [x] Phase 1 — Playwright pool + session management
- [x] Phase 2 — Supplier drivers + router (DHgate / Hoobuy / Kakobuy)
- [x] Phase 3 — Marketplace drivers + sold-polling + fulfillment
- [x] Phase 4 — Market scraping + fuzzy matching + opportunity ranker + daily digest
- [x] Phase 5 — Auto-listing + photo pipeline + rotation
- [x] Phase 6 — Account health + DM responder + repricer + reviews + competitor watch + P&L rollup
- [x] Phase 7 — Reshipper (Shipito) + pre-stock + dispute PDFs
- [x] Phase 8 — Scale levers (DHgate scout, WhatsApp bulk, account recovery)

## Operations

### Daily (5-10 min)
- Check `/digest` in Telegram
- Approve edge-case DMs flagged `needs_human_review`
- Tap `/post <SKU>` on ranked opportunities
- Review `/pnl` for yesterday

### Weekly (30 min)
- Review kill list from `/pnl`
- Launch 1-2 new accounts: `python -m scripts.login_<platform> --handle <h>`
  then `python -m scripts.warm_new_account --platform <p> --handle <h>`
- Scout new DHgate sellers: `python -m scripts.scout_dhgate_sellers --categories "<csv>"`

### Dispute drill
- `/dispute <sale_id>` → PDF delivered to Telegram, ready to upload to platform.

## Tests

Each phase ships smoke tests under `tests/test_phase<N>.py`. Run inside the
built container (host likely does not have the SQLAlchemy / Pillow / RapidFuzz
chain installed):

```bash
docker compose run --rm worker pytest -q
```
