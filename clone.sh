#!/usr/bin/env bash
set -e

usage() {
  cat <<EOF
Usage: ./clone.sh

Clone missing app repos and pull existing ones.
EOF
}

case "${1:-}" in
  "")
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 1
    ;;
esac

mkdir -p apps

APPS=(
  "apps/red-front|git@github.com:asipbajrami/red-front.git"
  "apps/red-back|git@github.com:asipbajrami/red-back.git"
)

sync_repo() {
  local repo_path="$1"
  local repo_url="$2"

  if [[ -d "$repo_path/.git" ]]; then
    echo "Pulling $repo_path"
    git -C "$repo_path" pull --ff-only
    rm -rf "$repo_path/.next"
    return
  fi

  if [[ -e "$repo_path" ]]; then
    echo "Error: $repo_path exists but is not a git repo"
    exit 1
  fi

  echo "Cloning $repo_path"
  git clone "$repo_url" "$repo_path"
}

for app in "${APPS[@]}"; do
  IFS="|" read -r repo_path repo_url <<< "$app"
  sync_repo "$repo_path" "$repo_url"
done

echo "Repo sync complete."
