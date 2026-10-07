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
- [ ] Phase 1 — Playwright pool + session management
- [ ] Phase 2 — Supplier drivers + router
- [ ] Phase 3 — Marketplace drivers + sold-polling + fulfillment
- [ ] Phase 4 — Market scraping + ranking + daily digest
- [ ] Phase 5 — Auto-listing + photo pipeline
- [ ] Phase 6 — Account health + growth
- [ ] Phase 7 — Reshipper + pre-stock + disputes
- [ ] Phase 8 — Scale levers
