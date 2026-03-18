#!/usr/bin/env bash
set -e

NO_CACHE=false

usage() {
  cat <<EOF
Usage: ./run.sh [options]

Start the development environment.

Options:
  --no-cache    Rebuild Docker images without using cache
  -h, --help    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-cache)
      NO_CACHE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

COMPOSE_FILE="docker-compose.dev.yml"
BACKEND_ENV="envs/.env.dev"
FRONTEND_ENV="envs/frontend.env.dev"
BACKEND_APP_ENV="apps/red-back/.env"
FRONTEND_APP_ENV="apps/red-front/.env.local"
COMPOSE_ARGS=(--env-file "$BACKEND_ENV" -f "$COMPOSE_FILE")

compose_dev() {
  docker compose "${COMPOSE_ARGS[@]}" "$@"
}

cp -n envs/.env.example "$BACKEND_ENV" 2>/dev/null || true
cp -n envs/frontend.env.example "$FRONTEND_ENV" 2>/dev/null || true
cp "$BACKEND_ENV" "$BACKEND_APP_ENV"
cp "$FRONTEND_ENV" "$FRONTEND_APP_ENV"

echo "Starting development environment..."
if [[ "$NO_CACHE" == true ]]; then
  echo "Rebuilding Docker images without cache..."
  compose_dev build --no-cache backend frontend
fi

compose_dev up --build -d

echo "Waiting for backend to become available..."
for i in $(seq 1 90); do
  if compose_dev exec -T backend php artisan about >/dev/null 2>&1; then
    break
  fi

  if [[ "$i" -eq 90 ]]; then
    echo "Error: backend did not become ready in time"
    compose_dev ps -a
    echo ""
    echo "Backend logs:"
    compose_dev logs backend --tail=200 || true
    exit 1
  fi

  sleep 2
done

echo "Running migrations and seeders..."
compose_dev exec -T backend php artisan migrate --seed --force

echo "Clearing application cache..."
compose_dev exec -T backend php artisan cache:clear

echo "Attaching to logs..."
compose_dev logs -f
