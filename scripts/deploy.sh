#!/usr/bin/env bash
# 호스트 stack(docker-compose.yml 을 가진 번호 디렉토리)을 EC2 로 배포합니다.
# 번호 순서대로 동기화하고 compose up 하므로, 새 stack 은 디렉토리만 추가하면 됩니다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v rsync >/dev/null || die "rsync 가 필요합니다 (sudo pacman -S rsync)"

instance_exists || die "인스턴스가 없습니다. make up 을 먼저 실행하세요."

SSH_NAME="$(ssh_hostname)" || die "접속 대상 호스트를 정하지 못했습니다."
HOST="ubuntu@$SSH_NAME"

# nginx 는 환경변수를 읽지 못하므로, 비밀 헤더 검증 스니펫을 rsync 전에 만듭니다.
# 이게 없으면 docker 가 마운트 지점에 빈 디렉토리를 만들고 nginx 가 기동에 실패합니다.
render_proxy_secret

# rsync 의 -e 는 작은따옴표는 해석하지만 백슬래시 이스케이프는 해석하지 않으므로
# printf '%q' 가 아니라 따옴표로 감싸야 경로의 공백이 살아남습니다.
SSH_CMD="ssh $(printf "'%s' " "${SSH_OPTS[@]}")"

mapfile -t STACKS < <(host_stacks)
[ "${#STACKS[@]}" -gt 0 ] || die "배포할 stack 이 없습니다"

# make deploy 를 단독으로 부를 수도 있으므로, 여기서도 호스트 상태를 확인합니다.
# (앞선 make down 이 중간에 실패했거나 재부팅된 경우)
ensure_host_ready "$HOST"

# compose 가 --env-file 로 읽는 설정. 모든 stack 이 공유합니다.
# secret 이 들어 있으므로 호스트에서도 600 으로 둡니다.
rsync -az --chmod=F600 -e "$SSH_CMD" "$ROOT/.env" "$HOST:/opt/stack/.env"

for s in "${STACKS[@]}"; do
  log "배포: $s"
  ssh "${SSH_OPTS[@]}" "$HOST" "mkdir -p /opt/stack/$s"

  # compose 는 bind mount 파일의 *내용*이 바뀌어도 컨테이너를 다시 만들지 않습니다.
  # prometheus.yml 같은 설정만 고치면 up -d 는 "Running" 이라고만 하고 끝납니다.
  # 그래서 실제로 바뀐 게 있을 때만 강제 재생성합니다.
  CHANGED="$(rsync -az --delete --itemize-changes -e "$SSH_CMD" "$ROOT/$s/" "$HOST:/opt/stack/$s/")"
  RECREATE=""
  if [ -n "$CHANGED" ]; then
    log "  변경 감지 — 컨테이너를 다시 만듭니다"
    RECREATE="--force-recreate"
  fi

  # pull 하지 않으면 태그를 올려도 캐시된 이미지가 계속 쓰입니다.
  # 다만 레지스트리 장애로 배포 전체가 멈추면 곤란하므로, 실패하면 캐시로 진행합니다.
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$HOST" "
    cd /opt/stack/$s
    docker compose --env-file /opt/stack/.env pull -q || echo '  pull 실패 — 캐시된 이미지로 진행합니다'
    docker compose --env-file /opt/stack/.env up -d --remove-orphans $RECREATE
  "
done

# Grafana 는 GF_SECURITY_ADMIN_PASSWORD 를 DB 최초 생성 시점에만 반영합니다.
# grafana-data 볼륨은 /data 에 남아 EC2 재생성에도 살아남으므로, 환경변수만으로는
# 한 번 만들어진 계정의 비밀번호가 절대 바뀌지 않습니다(= .env 를 고쳐도 무시됨).
# 배포할 때마다 명시적으로 맞춰줍니다. 멱등합니다.
#
# 값은 stdin 으로 넘깁니다. 원격에서 .env 를 다시 파싱하면 따옴표/공백 처리가
# lib.sh 의 source 와 달라져 "검증한 값"과 "실제 적용된 값"이 갈라집니다.
# stdin 이면 프로세스 목록에도 남지 않습니다.
if printf '%s\n' "${STACKS[@]}" | grep -q monitoring; then
  log "Grafana 기동 대기 후 admin 비밀번호를 .env 기준으로 동기화"
  # 갓 뜬 Grafana 에 CLI 를 붙이면 마이그레이터가 둘이 동시에 도는 상태가 됩니다.
  ready=false
  for _ in $(seq 1 30); do
    if ssh "${SSH_OPTS[@]}" "$HOST" \
      "docker exec grafana wget -qO- http://localhost:3000/api/health >/dev/null 2>&1"; then
      ready=true
      break
    fi
    sleep 2
  done

  if [ "$ready" = true ]; then
    printf '%s' "$GRAFANA_ADMIN_PASSWORD" | ssh "${SSH_OPTS[@]}" "$HOST" \
      "docker exec -i grafana grafana cli --homepath /usr/share/grafana admin reset-admin-password --password-from-stdin >/dev/null" ||
      log "  비밀번호 동기화 실패. make deploy 를 다시 실행하세요."
  else
    log "  Grafana 가 60초 안에 뜨지 않아 비밀번호 동기화를 건너뜁니다. make deploy 를 다시 실행하세요."
  fi
fi
