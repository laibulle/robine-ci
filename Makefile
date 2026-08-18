.DEFAULT_GOAL := dev

DATABASE_URL ?= postgres://postgres:postgres@localhost/robine_dev
ROBINE_BIND ?= 127.0.0.1:4004
ROBINE_PUBLIC_URL ?= http://localhost:4004

.PHONY: dev postgres

dev: postgres
	DATABASE_URL="$(DATABASE_URL)" \
	ROBINE_BIND="$(ROBINE_BIND)" \
	ROBINE_PUBLIC_URL="$(ROBINE_PUBLIC_URL)" \
	cargo run -p robine-server

postgres:
	docker compose up -d --wait postgres
