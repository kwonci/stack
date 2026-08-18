#!/usr/bin/env bash
# 호스트 접속. 인자를 주면 원격에서 실행합니다. 예: make ssh ARGS='docker ps'

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SSH_NAME="$(ssh_hostname)" || die "접속 대상 호스트를 정하지 못했습니다."
exec ssh "${SSH_OPTS[@]}" -t "ubuntu@$SSH_NAME" "$@"
