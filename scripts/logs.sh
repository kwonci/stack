#!/usr/bin/env bash
# 호스트 stack 의 로그를 봅니다.  make logs S=03-proxy

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STACK="${1:-}"
if [ -z "$STACK" ]; then
  echo "사용법: make logs S=<stack>   사용 가능:" >&2
  host_stacks | sed 's/^/  /' >&2
  exit 1
fi

SSH_NAME="$(ssh_hostname)" || die "접속 대상 호스트를 정하지 못했습니다."
exec ssh "${SSH_OPTS[@]}" -t "ubuntu@$SSH_NAME" \
  "cd /opt/stack/$STACK && docker compose --env-file /opt/stack/.env logs -f --tail=100"
