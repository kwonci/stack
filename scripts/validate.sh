#!/usr/bin/env bash
# AWS 나 S3 backend 없이 문법만 검사합니다. CI 나 편집 직후 확인용.
# lib.sh 를 쓰지 않습니다 — .env 없이도 돌아가야 하기 때문입니다.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for layer in "$ROOT"/[0-9][0-9]-*/; do
  [ -f "$layer/main.tf" ] || continue
  echo "==> $(basename "$layer") (terraform)"
  terraform -chdir="$layer" init -backend=false -input=false >/dev/null
  terraform -chdir="$layer" validate
done

# compose 는 변수 치환 때문에 env 파일이 필요합니다. .env 가 없으면 예시로 대체합니다.
ENV_FILE="$ROOT/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$ROOT/.env.example"

if ! command -v docker >/dev/null; then
  echo "==> docker 가 없어 compose 검사를 건너뜁니다"
  exit 0
fi

for stack in "$ROOT"/[0-9][0-9]-*/; do
  [ -f "$stack/docker-compose.yml" ] || continue
  echo "==> $(basename "$stack") (compose, env=$(basename "$ENV_FILE"))"
  docker compose -f "$stack/docker-compose.yml" --env-file "$ENV_FILE" config -q
done
