.PHONY: up down restart logs build shell

up:
		docker compose up -d

down:
		docker compose down

restart:
		docker compose restart

logs:
		docker compose logs -f

build:
		docker compose up -d --build

shell-nginx:
		docker exec -it nginx-proxy sh

shell-python:
		docker exec -it sheets-backend bash

backup:
		./scripts/backup.sh

rotate-logs:
  	find ./logs -name "*.log" -size +100M -exec truncate -s 0 {} \;

ps:
    docker compose ps

logs-nginx:
    docker compose logs -f nginx

logs-python:
    docker compose logs -f python

deploy:
    ./scripts/deploy.sh $(SITE)

ssl:
    docker compose run --rm certbot certonly --webroot \
        -w /var/www/certbot \
        -d savin-it.ru -d www.savin-it.ru \
        -d dev.savin-it.ru \
        --email vladimir.sjj@gmail.com \
        --agree-tos --no-eff-email

shell-mysql:
    docker exec -it mysql-db mysql -u root -p

backup:
    ./scripts/backup.sh

.DEFAULT_GOAL := up