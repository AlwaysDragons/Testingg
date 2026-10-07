.PHONY: bootstrap build up down logs ps restart test seed health post digest pnl shell psql clean

bootstrap:
	bash scripts/bootstrap.sh

build:
	docker compose build

up:
	docker compose up -d
	@echo
	@echo "stack booting. follow telegram with:  make logs"

down:
	docker compose down

logs:
	docker compose logs -f telegram worker scheduler

ps:
	docker compose ps

restart:
	docker compose restart scheduler worker telegram

test:
	docker compose run --rm worker pytest -q

seed:
	docker compose run --rm worker python -m scripts.seed_demo

shell:
	docker compose run --rm worker bash

psql:
	docker compose exec db psql -U ds -d dropship_mp

migrate:
	docker compose run --rm migrate alembic upgrade head

clean:
	docker compose down -v
	@echo "all volumes gone. this wipes Postgres and the session store."
