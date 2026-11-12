SHELL := /bin/sh
COMPOSE := docker compose

.PHONY: pki up down logs status

# test PKI in security/ (kept when present; ./scripts/generate-pki.sh --force regenerates it)
pki:
	@./scripts/generate-pki.sh

up: pki
	@$(COMPOSE) up -d --wait

down:
	@$(COMPOSE) down

logs:
	@$(COMPOSE) logs -f --tail=100

status:
	@$(COMPOSE) ps
