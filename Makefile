.PHONY: data build up down smoke test fmt

data:
	cp /Users/samuel/Documents/Personal/rinha-backend-26/bench/references.json.gz data/references.json.gz

build:
	docker compose -f deploy/docker-compose.yml build

up:
	docker compose -f deploy/docker-compose.yml up -d

down:
	docker compose -f deploy/docker-compose.yml down -v

smoke:
	curl -fsS http://localhost:9999/ready
	curl -fsS http://localhost:9999/fraud-score -X POST -H 'Content-Type: application/json' -d @data/sample.json | jq

test:
	zig build test

fmt:
	zig fmt build.zig src cmd
