.PHONY: up down restart logs build shell

up:
	docker-compose up -d

down:
	docker-compose down

restart:
	docker-compose restart

logs:
	docker-compose logs -f

build:
	docker-compose up -d --build

shell-nginx:
	docker exec -it nginx-proxy sh

shell-python:
	docker exec -it sheets-backend bash

rotate-logs:
	find ./logs -name "*.log" -size +100M -exec truncate -s 0 {} \;
