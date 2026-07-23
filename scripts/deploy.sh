#!/bin/bash

set -e

IMAGE_TAG=${IMAGE_TAG:-latest}

echo "Deploying image: $IMAGE_TAG"

export IMAGE_TAG

docker compose -f docker-compose.production.yml pull
docker compose -f docker-compose.production.yml up -d

docker compose -f docker-compose.production.yml exec -T app php artisan migrate --force
docker compose -f docker-compose.production.yml exec -T app php artisan optimize

echo "Deployment completed."