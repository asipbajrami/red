#!/usr/bin/env bash
set -e

MIGRATE=false
SEED=false
SERVICES=""

usage() {
  cat <<EOF
Usage: ./deploy.sh [options]

Production deployment script. For development, use ./run.sh instead.

Options:
  -m            Run database migrations after deploy
  -S            Run database seeders after deploy
  -s <services> Deploy specific services (comma-separated: frontend,backend,nginx,db)
  -h            Show this help
EOF
  exit 0
}

while getopts "mSs:h" opt; do
  case $opt in
    m) MIGRATE=true ;;
    S) SEED=true ;;
    s) SERVICES="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

COMPOSE_FILE="docker-compose.prod.yml"
BACKEND_ENV="envs/.env.prod"
FRONTEND_ENV="envs/frontend.env.prod"
BACKEND_APP_DIR="apps/red-back"
FRONTEND_APP_DIR="apps/red-front"
BACKEND_APP_ENV="$BACKEND_APP_DIR/.env"
FRONTEND_APP_ENV="$FRONTEND_APP_DIR/.env.local"
NGINX_TEMPLATE="nginx/prod.conf.template"
NGINX_CONFIG="nginx/prod.conf"
APPS=(
  "$FRONTEND_APP_DIR"
  "$BACKEND_APP_DIR"
)

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Error: $COMPOSE_FILE not found"
  exit 1
fi

if [[ ! -f "$BACKEND_ENV" || ! -f "$FRONTEND_ENV" ]]; then
  echo "Error: production env files are missing"
  exit 1
fi

if grep -q "CHANGE_ME" "$BACKEND_ENV"; then
  echo "Warning: $BACKEND_ENV contains placeholder secrets"
  read -rp "Continue anyway? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
fi

if grep -q "^APP_KEY=$" "$BACKEND_ENV"; then
  echo "Error: APP_KEY is not set in $BACKEND_ENV"
  exit 1
fi

echo "==> Syncing app repos..."
./clone.sh

for app in "${APPS[@]}"; do
  if [[ ! -d "$app/.git" ]]; then
    echo "Error: $app is missing or is not a git repo"
    exit 1
  fi
done

echo "==> Copying environment files..."
cp "$BACKEND_ENV" "$BACKEND_APP_ENV"
cp "$FRONTEND_ENV" "$FRONTEND_APP_ENV"

set -a
source "$BACKEND_ENV"
set +a

: "${FRONTEND_DOMAIN:?FRONTEND_DOMAIN must be set in $BACKEND_ENV}"
: "${API_DOMAIN:?API_DOMAIN must be set in $BACKEND_ENV}"

SSL_CERT_FILENAME="${SSL_CERT_FILENAME:-origin.pem}"
SSL_KEY_FILENAME="${SSL_KEY_FILENAME:-origin.key}"

echo "==> Rendering Nginx production config..."
mkdir -p certs
sed \
  -e "s|__FRONTEND_DOMAIN__|$FRONTEND_DOMAIN|g" \
  -e "s|__API_DOMAIN__|$API_DOMAIN|g" \
  -e "s|__SSL_CERT_FILENAME__|$SSL_CERT_FILENAME|g" \
  -e "s|__SSL_KEY_FILENAME__|$SSL_KEY_FILENAME|g" \
  "$NGINX_TEMPLATE" > "$NGINX_CONFIG"

COMPOSE_CMD="docker compose --env-file $BACKEND_ENV -f $COMPOSE_FILE up -d --build"

if [[ -n "$SERVICES" ]]; then
  COMPOSE_CMD="$COMPOSE_CMD ${SERVICES//,/ }"
fi

echo "==> Running: $COMPOSE_CMD"
$COMPOSE_CMD

echo "==> Waiting for services to be healthy..."
MAX_RETRIES=30
RETRY_INTERVAL=10

for i in $(seq 1 $MAX_RETRIES); do
  UNHEALTHY=$(docker compose --env-file "$BACKEND_ENV" -f "$COMPOSE_FILE" ps --format json 2>/dev/null | grep -c '"Health":"starting"' || true)

  if [[ "$UNHEALTHY" -eq 0 ]]; then
    echo "  All services healthy"
    break
  fi

  if [[ "$i" -eq "$MAX_RETRIES" ]]; then
    echo "  Warning: some services may not be healthy after ${MAX_RETRIES} retries"
    docker compose --env-file "$BACKEND_ENV" -f "$COMPOSE_FILE" ps
    break
  fi

  echo "  Waiting... ($i/$MAX_RETRIES)"
  sleep "$RETRY_INTERVAL"
done

if [[ "$MIGRATE" == true ]]; then
  echo "==> Running database migrations..."
  docker compose --env-file "$BACKEND_ENV" -f "$COMPOSE_FILE" exec backend php artisan migrate --force
fi

if [[ "$SEED" == true ]]; then
  echo "==> Running database seeders..."
  docker compose --env-file "$BACKEND_ENV" -f "$COMPOSE_FILE" exec backend php artisan db:seed --force
fi

echo "==> Clearing application cache..."
docker compose --env-file "$BACKEND_ENV" -f "$COMPOSE_FILE" exec backend php artisan cache:clear

echo ""
echo "==> Deployment complete"
docker compose --env-file "$BACKEND_ENV" -f "$COMPOSE_FILE" ps
