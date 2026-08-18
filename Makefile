.DEFAULT_GOAL := dev

ENV_FILE ?= .env

.PHONY: dev postgres check-env

dev: check-env postgres
	set -a; . "./$(ENV_FILE)"; set +a; cargo run -p robine-server

postgres:
	docker compose up -d --wait postgres

check-env:
	@test -f "$(ENV_FILE)" || { \
		echo "$(ENV_FILE) is missing; copy .env.example to $(ENV_FILE)"; \
		exit 1; \
	}
