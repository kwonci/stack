#!/usr/bin/env bash
# stack 을 켭니다. 01 -> 02 -> 호스트 배포 순서.
# 이미 켜져 있으면 변경분만 반영합니다 (멱등).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TF_VAR_tfstate_bucket="$(tfstate_bucket)"
export TF_VAR_tfstate_bucket

# 모든 트래픽이 터널로만 들어오므로, zone 권한이 Cloudflare 에 있어야 어떤
# 호스트도 해석되지 않습니다. NS 가 안 넘어갔으면 배포 전에 막습니다.
#
# 이 검사는 반드시 01-foundation apply 보다 **먼저** 와야 합니다. apply 가 예전
# Route53 와일드카드 레코드를 지우는데, NS 가 아직 Route53 를 가리키는 동안
# 그러면 도메인이 통째로 해석되지 않습니다. 검사가 terraform 출력에 의존하지
# 않고 dig 만 쓰는 것도 그래서입니다.
if ! delegated; then
  echo
  log "$DOMAIN 의 NS 가 Cloudflare 를 가리키지 않습니다."
  echo "  현재 NS:"
  (dig +short NS "$DOMAIN" 2>/dev/null || echo "    (dig 이 없어 조회하지 못했습니다)") |
    sed 's/^/    /'
  echo
  echo "  Cloudflare 대시보드에서 zone 을 추가하고, 안내되는 NS 2개를"
  echo "  도메인 등록기관에 등록하세요. 그 전에 기존 레코드(blog 등)를 먼저"
  echo "  Cloudflare 쪽에 옮겨두어야 전환 순간에 끊기지 않습니다."
  echo
  echo "  전파 확인:  dig +short NS $DOMAIN"
  echo "  그 뒤에 다시:  make up"
  echo
  die "Cloudflare 가 zone 권한을 갖기 전에는 어떤 호스트도 해석되지 않으므로 여기서 멈춥니다."
fi

log "01-foundation apply"
tf 01-foundation apply -input=false -auto-approve


# user_data 나 AMI 가 바뀌면 인스턴스가 교체됩니다. 그 경우 볼륨이 마운트된 채
# force detach 되므로, apply 전에 호스트를 안전하게 내려야 합니다.
PLAN="$(mktemp)"
trap 'rm -f "$PLAN"' EXIT

log "02-compute plan"
tf 02-compute plan -input=false -out="$PLAN" >/dev/null

PLAN_ACTION="$(plan_host_action "$PLAN")" ||
  die "plan 분석에 실패했습니다. 마운트된 볼륨을 떼는 위험이 있어 중단합니다."
read -r INSTANCE_ACTION QUIESCE <<<"$PLAN_ACTION"

if [ "$QUIESCE" = quiesce ]; then
  log "인스턴스/볼륨 연결이 교체됩니다. 먼저 호스트를 안전하게 정지합니다."
  quiesce_host
fi

log "02-compute apply"
tf 02-compute apply -input=false "$PLAN"

SSH_NAME="$(ssh_hostname)" || die "접속 대상 호스트를 정하지 못했습니다."
HOST="ubuntu@$SSH_NAME"

# 새로 만들어진 인스턴스는 같은 이름에 다른 host key 로 뜹니다.
# make down 뒤의 make up 은 delete 없이 create 만 나오므로 여기서도 지워야 합니다.
# 반대로 아무 변화가 없었으면 건드리지 않습니다 — 매번 지우면 host key 검증이
# 사실상 꺼지고, 그 세션으로 .env(비밀번호 포함)가 건너갑니다.
if [ "$INSTANCE_ACTION" != none ]; then
  forget_host_key "$SSH_NAME"
fi

# 인스턴스가 새로 떴다면 cloudflared 가 설치되고 터널이 Cloudflare 에 등록될
# 때까지는 접속이 안 됩니다. cloud-init 이 docker 보다 cloudflared 를 먼저
# 세우므로 보통 1~2분이지만, 등록이 늦을 수 있어 넉넉히 기다립니다.
log "SSH 대기: $HOST"
ready=false
for _ in $(seq 1 90); do
  if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "$HOST" true 2>/dev/null; then
    ready=true
    break
  fi
  sleep 5
done
[ "$ready" = true ] || die "7분 30초 동안 SSH 응답이 없습니다.
  터널이 뜨지 않았을 수 있습니다. Cloudflare 대시보드에서 터널 상태를 보거나,
  SSM 으로 들어가 확인하세요 (인바운드를 열 필요도, apply 를 다시 돌 필요도 없습니다):
    SSH_VIA=ssm make ssh ARGS='journalctl -u cloudflared -n 50'
    SSH_VIA=ssm make ssh ARGS='sudo tail -50 /var/log/cloud-init-output.log'"

log "cloud-init 완료 대기 (docker 설치 + /data 마운트)"
# exit code: 0=done, 2=degraded(경고), 그 외=실패
rc=0
ssh "${SSH_OPTS[@]}" "$HOST" "sudo cloud-init status --wait" || rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  ssh "${SSH_OPTS[@]}" "$HOST" "sudo tail -50 /var/log/cloud-init-output.log" || true
  die "cloud-init 실패(rc=$rc). 고친 뒤 make down && make up 으로 재생성하세요."
fi

"$ROOT/scripts/deploy.sh"

log "완료:  https://grafana.$DOMAIN  (Cloudflare Access 로그인 후)"
echo "  공개 서비스는 컨테이너에 VIRTUAL_HOST 를 달면 즉시 붙습니다. 진행 상황:  make logs S=03-proxy"
