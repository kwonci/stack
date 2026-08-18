#!/usr/bin/env bash
# 모든 스크립트가 source 하는 공통부.
# .env 하나만 읽어서 terraform(TF_VAR_*)과 docker compose 양쪽에 흘려보냅니다.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$ROOT/.env" ] || die ".env 가 없습니다. cp .env.example .env 후 채우세요."

set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a

: "${PROJECT:?}" "${AWS_REGION:?}" "${AWS_AZ:?}" "${DOMAIN:?}"

# DOMAIN 은 Cloudflare zone 이름 그 자체입니다. 이 stack 이 zone 하나를 통째로
# 점유한다는 컨벤션이라 둘을 나누지 않습니다 (01-foundation/variables.tf 참고).
case "$DOMAIN" in
  *.*.*) die "DOMAIN($DOMAIN) 이 zone 이 아니라 하위 도메인으로 보입니다.
  이 stack 은 zone 하나를 통째로 점유합니다. 하위로 내리면 Universal SSL 범위를
  벗어나 유료 인증서가 필요해집니다 — README 의 '도메인 컨벤션' 참고." ;;
esac

# 이 토큰이 없으면 cloudflared 가 뜨지 않고, SG 에 인바운드 규칙이 하나도 없으므로
# 호스트에 들어갈 방법 자체가 사라집니다. 배포 전에 막습니다.
: "${CLOUDFLARE_API_TOKEN:?.env 에 CLOUDFLARE_API_TOKEN 을 설정하세요 (README 의 토큰 권한 목록)}"
: "${CLOUDFLARE_ACCOUNT_ID:?.env 에 CLOUDFLARE_ACCOUNT_ID 를 설정하세요}"
: "${ACCESS_EMAILS:?.env 에 ACCESS_EMAILS 를 설정하세요. 비면 SSH 조차 막힙니다}"

# Cloudflare 의 Transform Rule 이 넣고 nginx 가 확인하는 공유 비밀입니다.
# 터널 전용이 된 뒤로는 필수 방어선이 아니지만(우회할 직접 경로가 없음),
# 양쪽이 같은 값을 써야 하므로 검증은 그대로 둡니다.
: "${CF_ORIGIN_SECRET:?.env 에 CF_ORIGIN_SECRET 을 설정하세요 (openssl rand -hex 32)}"
[ "${#CF_ORIGIN_SECRET}" -ge 32 ] ||
  die "CF_ORIGIN_SECRET 이 너무 짧습니다(32자 이상). openssl rand -hex 32 로 만드세요."

# Grafana 앞에 Cloudflare Access 가 있지만, 그건 Cloudflare 계정이 뚫리거나
# Access 정책을 잘못 열었을 때를 대비하지 못합니다. 자리표시자로 뜨면 안 됩니다.
: "${GRAFANA_ADMIN_PASSWORD:?.env 에 GRAFANA_ADMIN_PASSWORD 를 설정하세요}"
case "$GRAFANA_ADMIN_PASSWORD" in
  change-me | changeme | admin | password)
    die "GRAFANA_ADMIN_PASSWORD 가 기본값입니다. 실제 비밀번호로 바꾸세요."
    ;;
esac
# 최초 DB 생성은 짧은 비밀번호도 받아주지만 reset-admin-password 는 거부하므로,
# 짧게 두면 .env 를 고쳐도 실제 비밀번호가 영영 안 바뀝니다. 넉넉히 8자로 막습니다.
[ "${#GRAFANA_ADMIN_PASSWORD}" -ge 8 ] ||
  die "GRAFANA_ADMIN_PASSWORD 가 너무 짧습니다(8자 이상)."

export AWS_DEFAULT_REGION="$AWS_REGION"

export TF_VAR_project="$PROJECT"
export TF_VAR_region="$AWS_REGION"
export TF_VAR_availability_zone="$AWS_AZ"
export TF_VAR_data_volume_size="${DATA_VOLUME_SIZE:?}"
export TF_VAR_data_snapshot_id="${DATA_SNAPSHOT_ID:-}"
export TF_VAR_ssh_public_key_path="${SSH_PUBLIC_KEY_PATH:?}"
export TF_VAR_instance_type="${INSTANCE_TYPE:?}"
export TF_VAR_instance_arch="${INSTANCE_ARCH:?}"
export TF_VAR_root_volume_size="${ROOT_VOLUME_SIZE:?}"

SSH_KEY="$(eval echo "${SSH_PRIVATE_KEY_PATH:?}")"
[ -f "$SSH_KEY" ] || die "개인키가 없습니다: $SSH_KEY (.env 의 SSH_PRIVATE_KEY_PATH)"

# plan 분석과 NS 확인이 python3 에 의존합니다. 두 검사 모두 실패 시 중단하도록
# 되어 있지만, 그러면 원인이 불분명한 채로 멈추므로 여기서 미리 걸러냅니다.
command -v python3 >/dev/null || die "python3 가 필요합니다."

SSH_OPTS=(
  -i "$SSH_KEY"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$ROOT/.ssh_known_hosts"
  # 사용자의 ~/.ssh/config 가 ControlMaster 를 켜두면 cloud-init 이 끝나기 전에
  # 열린 세션이 재사용되어 docker 그룹 권한이 반영되지 않습니다.
  -o ControlMaster=no
  -o ControlPath=none
)

# 접속 경로는 두 가지뿐이고, 둘 다 인바운드 포트를 쓰지 않습니다.
# SSH_VIA 로 고릅니다 (.env 가 아니라 그때그때: `SSH_VIA=ssm make ssh`).
#
#   tunnel (기본) : cloudflared 터널. 대상은 ssh.<domain>, 앞을 Access 가 막습니다.
#   ssm  (복구용) : SSM Session Manager. 대상은 인스턴스 ID.
#
# ssm 이 브레이크글라스인 이유는 실패 도메인이 겹치지 않기 때문입니다. Cloudflare
# 와 무관하고, 아웃바운드만 쓰므로 SG 를 열 필요가 없고(= 복구 시점에 terraform
# apply 가 필요 없고), 에이전트는 stack-init.sh 가 아니라 AMI 에서 옵니다.
# 즉 cloud-init 이 중간에 죽어도 살아 있습니다.
#
# 어느 쪽이든 SSH 자체는 같은 key pair 로 붙습니다. ssm 은 세션을 터널로만 쓰므로
# rsync 와 quiesce_host 까지 그대로 동작합니다 — deploy 도 down 도 됩니다.
SSH_VIA="${SSH_VIA:-tunnel}"

case "$SSH_VIA" in
  tunnel)
    command -v cloudflared >/dev/null ||
      die "cloudflared 가 없습니다. 평상시 SSH 는 이걸로만 들어갑니다.
  설치: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
  터널이 죽었을 때는 SSH_VIA=ssm 으로 우회할 수 있습니다."
    SSH_OPTS+=(-o "ProxyCommand=cloudflared access ssh --hostname %h")
    ;;
  ssm)
    command -v aws >/dev/null || die "awscli 가 필요합니다."
    # 플러그인은 awscli 와 별개 패키지입니다. 없으면 start-session 이
    # "SessionManagerPlugin is not found" 로 죽습니다.
    command -v session-manager-plugin >/dev/null ||
      die "session-manager-plugin 이 없습니다. SSM 접속에 필요합니다.
  설치: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
    SSH_OPTS+=(-o "ProxyCommand=aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p")
    ;;
  *)
    die "SSH_VIA 는 tunnel 또는 ssm 이어야 합니다 (받은 값: $SSH_VIA)"
    ;;
esac

# ssh/rsync 가 붙을 대상. 위 분기와 반드시 짝이 맞아야 합니다.
# 명령 치환 안에서 die 가 삼켜지므로 호출부는 `|| die` 를 따로 붙일 것.
ssh_hostname() {
  if [ "$SSH_VIA" = ssm ]; then
    instance_id
  else
    printf 'ssh.%s\n' "$DOMAIN"
  fi
}

# 명령 치환 안에서 die 를 호출하면 종료 코드가 삼켜지므로, 호출부는
# `export x="$(...)"` 대신 두 줄로 나눠 쓸 것.
tfstate_bucket() {
  [ -f "$ROOT/backend.hcl" ] || die "backend.hcl 이 없습니다. make bootstrap 을 먼저 실행하세요."
  awk -F'"' '/^bucket/ {print $2}' "$ROOT/backend.hcl"
}

# .env 에서 각 레이어의 terraform.tfvars 를 생성합니다.
#
# 설정의 단일 소스는 여전히 .env 입니다. tfvars 는 파생물이고 gitignore 됩니다.
# 굳이 만드는 이유는 make 래퍼 없이도 terraform 을 직접 돌릴 수 있게 하기 위함입니다
# (terraform -chdir=01-foundation plan 등). TF_VAR_* 도 그대로 내보내지만 tfvars
# 쪽이 우선순위가 높고, 둘 다 같은 순간 같은 값에서 나오므로 어긋나지 않습니다.
#
# 값은 python 으로 HCL 문자열 리터럴로 인코딩합니다. 손으로 따옴표를 붙이면
# ${...} 보간이나 백슬래시가 있는 값에서 조용히 다른 값이 됩니다.
write_tfvars() {
  local layer="$1"; shift
  python3 - "$ROOT/$layer/terraform.tfvars" "$@" <<'PY'
import json, os, sys

path, pairs = sys.argv[1], sys.argv[2:]

def hcl(v):
    # JSON 문자열 이스케이프를 쓰되, HCL 의 보간 시작 토큰은 추가로 막습니다.
    return json.dumps(v).replace("${", "$${").replace("%{", "%%{")

lines = ["# scripts/lib.sh 가 .env 에서 생성합니다. 직접 고치지 마세요.\n"]
for p in pairs:
    k, _, v = p.partition("=")
    lines.append(f"{k} = {hcl(v)}\n")

with open(path, "w") as f:
    f.writelines(lines)
# 01-foundation 의 tfvars 에는 API 토큰이 들어갑니다. .env 와 같은 등급으로 둡니다.
os.chmod(path, 0o600)
PY
}

# 하나의 terraform 레이어를 init + 명령 실행
tf() {
  local layer="$1"; shift

  case "$layer" in
    00-global)
      write_tfvars "$layer" \
        "project=$PROJECT" "region=$AWS_REGION"
      ;;
    01-foundation)
      write_tfvars "$layer" \
        "project=$PROJECT" "region=$AWS_REGION" "availability_zone=$AWS_AZ" \
        "data_volume_size=$DATA_VOLUME_SIZE" \
        "data_snapshot_id=${DATA_SNAPSHOT_ID:-}" \
        "ssh_public_key_path=$SSH_PUBLIC_KEY_PATH" \
        "domain=$DOMAIN" \
        "cloudflare_api_token=$CLOUDFLARE_API_TOKEN" \
        "cloudflare_account_id=$CLOUDFLARE_ACCOUNT_ID" \
        "origin_secret=$CF_ORIGIN_SECRET"
      # 리스트라 문자열 인코더를 못 쓰므로 따로 덧붙입니다.
      python3 - "$ROOT/$layer/terraform.tfvars" "$ACCESS_EMAILS" <<'EOF'
import json, sys
path, raw = sys.argv[1], sys.argv[2]
emails = [e.strip() for e in raw.split(",") if e.strip()]
with open(path, "a") as f:
    f.write("access_emails = " + json.dumps(emails) + "\n")
EOF
      ;;
    02-compute)
      write_tfvars "$layer" \
        "project=$PROJECT" "region=$AWS_REGION" \
        "tfstate_bucket=${TF_VAR_tfstate_bucket:-}" \
        "instance_type=$INSTANCE_TYPE" "instance_arch=$INSTANCE_ARCH" \
        "root_volume_size=$ROOT_VOLUME_SIZE"
      ;;
  esac

  terraform -chdir="$ROOT/$layer" init -input=false -reconfigure \
    -backend-config="$ROOT/backend.hcl" >/dev/null
  terraform -chdir="$ROOT/$layer" "$@"
}

# SSM 의 접속 대상. 02 의 state 에서 읽습니다.
# make ssh 처럼 앞서 init 이 돌지 않은 경로에서도 불리므로 여기서 직접 init 합니다.
instance_id() {
  terraform -chdir="$ROOT/02-compute" init -input=false -reconfigure \
    -backend-config="$ROOT/backend.hcl" >/dev/null 2>&1 ||
    die "02-compute init 에 실패했습니다. 인스턴스 ID 를 알 수 없어 중단합니다."
  terraform -chdir="$ROOT/02-compute" output -raw instance_id
}

# 02 에 인스턴스가 실제로 있는지. 여러 곳에서 "볼륨을 떼도 되는가"의 판단 근거로
# 쓰이므로, 확인 자체가 실패했을 때 "없다"로 답하면 안 됩니다.
# init 실패와 "state 가 비어 있음"은 둘 다 stdout 이 비고 rc 가 1 이라 구분되지
# 않으므로, init 을 따로 떼어 먼저 실패시킵니다. init 이 성공한 뒤의 실패는
# state 가 없다는 뜻이고, 그건 곧 인스턴스가 없다는 뜻입니다.
instance_exists() {
  terraform -chdir="$ROOT/02-compute" init -input=false -reconfigure \
    -backend-config="$ROOT/backend.hcl" >/dev/null 2>&1 ||
    die "02-compute init 에 실패했습니다. 인스턴스 유무를 확인할 수 없어 중단합니다."

  local out err rc=0
  err="$(mktemp)"
  out="$(terraform -chdir="$ROOT/02-compute" state list 2>"$err")" || rc=$?
  # init 이 성공했으면 여기서의 실패는 "state 가 없다"= 인스턴스가 없다는 뜻입니다.
  # 그래도 이유는 보여줍니다 — 조용한 판정 실패가 이 stack 의 단골 사고였습니다.
  if [ "$rc" -ne 0 ] && [ -s "$err" ]; then
    log "02-compute state 조회 경고: $(head -n 3 "$err" | tr '\n' ' ')"
  fi
  rm -f "$err"

  grep -qx 'aws_instance.main' <<<"$out"
}

# 스냅샷 목록. volume-id 로 거르면 한 번 복구한 뒤에는 예전 볼륨의 스냅샷이
# 전부 사라져 버리므로(복구에 쓸 바로 그 스냅샷 포함) Project 태그로 거릅니다.
# 태그를 붙여 주는 것은 EBS 가 아니라 provider 입니다(final_snapshot 을 만들 때
# tags_all 을 TagSpecifications 로 넘김). 그래서 콘솔에서 손으로 만든 스냅샷이나
# Project 태그를 안 붙이는 DLM 정책의 스냅샷은 여기 안 잡힙니다.
list_snapshots() {
  aws ec2 describe-snapshots --owner-ids self \
    --filters "Name=tag:Project,Values=$PROJECT" \
    --query 'reverse(sort_by(Snapshots,&StartTime))[].[SnapshotId,StartTime,State,VolumeSize]' \
    --output text
}

# 호스트 stack 의 정의는 한 곳에만 둡니다: docker-compose.yml 을 가진 번호 디렉토리.
# 번호로 판단하면 나중에 terraform 레이어를 추가했을 때 compose up 을 시도하게 됩니다.
host_stacks() {
  local d
  for d in "$ROOT"/[0-9][0-9]-*/; do
    [ -f "$d/docker-compose.yml" ] || continue
    basename "$d"
  done
}

# zone 의 권한이 실제로 Cloudflare 에 있는지.
#
# 이 stack 의 모든 경로는 Cloudflare 가 zone 권한을 갖고 있다는 전제 위에 있습니다.
# 공개 서비스도 Grafana 도 SSH 도 전부 <tunnel-id>.cfargotunnel.com 을 가리키는
# CNAME 으로 닿는데, 그 레코드는 Cloudflare 엣지 안에서만 의미가 있습니다.
# NS 가 아직 안 넘어갔으면 어느 것도 해석되지 않습니다.
#
# 확인할 수 없을 때는 통과가 아니라 차단이 기본값입니다. SKIP_NS_CHECK=1 로 넘깁니다.
delegated() {
  [ "${SKIP_NS_CHECK:-0}" = "1" ] && return 0
  command -v dig >/dev/null || return 1

  dig +short NS "$DOMAIN" 2>/dev/null |
    tr '[:upper:]' '[:lower:]' | grep -q '\.ns\.cloudflare\.com\.$'
}

# nginx 설정은 환경변수를 읽지 못하므로, 비밀 헤더 검증 스니펫만 배포 직전에
# .env 값으로 만들어 둡니다. 결과 파일은 값이 secret 이라 gitignore 됩니다.
# 내용이 매번 똑같아야 rsync 가 변경으로 보지 않고, 컨테이너를 쓸데없이
# 재생성하지 않습니다 (deploy.sh 가 rsync 출력으로 --force-recreate 를 정함).
render_proxy_secret() {
  mkdir -p "$ROOT/03-proxy/vhost.d"
  {
    cat <<'EOF'
# scripts/lib.sh 가 .env 의 CF_ORIGIN_SECRET 으로 생성합니다. 직접 고치지 마세요.
#
# nginx-proxy 가 각 server 블록에 include 합니다. Cloudflare 의 Transform Rule 이
# 모든 요청에 넣어주는 X-Origin-Secret 을 확인해, 없으면 끊습니다.
#
# 이 리스너는 127.0.0.1:80 에만 있고 SG 에 인바운드 규칙도 없으므로, 애초에
# 호스트의 cloudflared 말고는 아무도 여기 닿지 못합니다. 즉 이 검증은 이제
# 필수가 아니라 한 겹 더입니다. Transform Rule(01-foundation/cloudflare.tf)을
# 지운다면 이 파일을 만드는 함수도 같이 지워야 합니다 — 한쪽만 없애면 전부 403 입니다.
set $origin_ok 0;
EOF
    printf 'if ($http_x_origin_secret = "%s") { set $origin_ok 1; }\n' "$CF_ORIGIN_SECRET"
    cat <<'EOF'
if ($origin_ok = 0) { return 403; }
EOF
  } >"$ROOT/03-proxy/vhost.d/default"
}

# 저장된 plan 을 읽어 두 가지를 한 번에 답합니다. "<인스턴스 동작> <quiesce 여부>"
#
#   인스턴스 동작: none | create | replace
#     -> create 든 replace 든 새 인스턴스는 새 host key 를 갖습니다. 접속 대상
#        이름(ssh.<domain>)은 그대로인데 key 만 바뀌므로 known_hosts 를 지워야 합니다.
#        make down 뒤의 make up 은 state 가 비어 있어 delete 없이 create 만
#        나오므로, replace 만 보면 이 경우를 놓칩니다.
#   quiesce 여부: 인스턴스나 볼륨 attachment 가 교체되면 필요합니다.
#
# 확인 자체가 실패했을 때 "아무 일도 없음"으로 넘어가면 마운트된 볼륨을 그대로
# force detach 하게 되므로, 판정 불가는 통과가 아니라 중단입니다.
plan_host_action() {
  terraform -chdir="$ROOT/02-compute" show -json "$1" | python3 -c '
import sys, json

d = json.load(sys.stdin)
instance, quiesce = "none", "noquiesce"

for c in d.get("resource_changes", []):
    addr, a = c["address"], c["change"]["actions"]
    replaced = "delete" in a and "create" in a

    if addr in ("aws_instance.main", "aws_volume_attachment.data") and replaced:
        quiesce = "quiesce"

    if addr == "aws_instance.main":
        if replaced:
            instance = "replace"
        elif "create" in a:
            instance = "create"

print(instance, quiesce)
'
}

# quiesce 이후 destroy 가 실패했거나, 재부팅 등으로 호스트가 어정쩡한 상태로
# 남아 있을 때 정상 상태로 되돌립니다. terraform 은 이런 drift 를 보지 못합니다.
ensure_host_ready() {
  ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 "$1" 'sudo bash -s' <<'REMOTE' || die "호스트를 정상 상태로 되돌리지 못했습니다. make ssh 로 들어가 확인하세요."
set -u
if ! mountpoint -q /data; then
  mount /data || { echo "/data 마운트 실패" >&2; exit 1; }
fi
if ! systemctl is-active --quiet docker; then
  systemctl start docker || { journalctl -u docker -n 20 --no-pager >&2; exit 1; }
fi
docker info >/dev/null 2>&1 || { journalctl -u docker -n 20 --no-pager >&2; exit 1; }
exit 0
REMOTE
}

# 접속 대상 이름은 그대로지만 인스턴스를 새로 만들면 host key 가 바뀝니다.
# StrictHostKeyChecking=accept-new 는 '모르는 호스트'만 받아주고
# '바뀐 호스트'는 거부하므로, 인스턴스가 새로 생긴 직후에는 낡은 항목을 지워야 합니다.
# 단 up.sh 가 plan 상 인스턴스가 create/replace 될 때만 부릅니다. 매번 지우면
# host key 검증이 사실상 꺼지고, 그 세션으로 .env(비밀번호 포함)가 건너갑니다.
forget_host_key() {
  ssh-keygen -R "$1" -f "$ROOT/.ssh_known_hosts" >/dev/null 2>&1 || true
}

# 데이터 볼륨을 떼기 전에 docker 를 완전히 멈추고 /data 를 언마운트합니다.
# 마운트된 채로 force detach 하면 파일시스템이 깨집니다.
#
# docker.service 와 containerd.service 는 둘 다 KillMode=process 라서 unit 을
# 멈춰도 shim 은 살아남습니다. overlay2 의 merged 마운트를 실제로 걷어내는 것은
# 앞의 docker stop 이고, 그러고도 남는 하위 마운트가 있으면 /data 언마운트는
# 무조건 EBUSY 로 실패합니다. 그래서 하위 마운트부터 역순으로 떼어냅니다.
#
# 인스턴스가 애초에 없으면 할 일이 없습니다. 다만 "접속이 안 된다"를 근거로
# 삼으면 안 됩니다 — SSH 실패는 인스턴스 부재만큼이나 터널 장애나 일시적 문제를
# 뜻할 수 있고, 그 상태에서 그냥 진행하면 살아 있는 볼륨을 마운트된 채로 뜯게
# 됩니다.
# 그래서 판단 기준은 02 state 에 인스턴스가 있느냐입니다.
quiesce_host() {
  instance_exists || {
    log "02-compute 에 인스턴스가 없습니다. 정지할 것이 없어 넘어갑니다."
    return 0
  }

  local name host
  name="$(ssh_hostname)" || die "접속 대상 호스트를 정하지 못했습니다."
  [ -n "$name" ] || die "접속 대상 호스트가 비어 있습니다."
  host="ubuntu@$name"

  ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 "$host" true 2>/dev/null ||
    die "인스턴스는 존재하는데 SSH 가 되지 않습니다. 마운트된 볼륨을 뜯을 위험이 있어 중단합니다.
  터널이 죽었다면 SSM 으로 우회하세요 — terraform apply 도 SG 변경도 필요 없습니다.
    SSH_VIA=ssm make ssh     (확인)
    SSH_VIA=ssm make down    (그대로 내리기)
  호스트가 응답하지 않으면 콘솔에서 정지시킨 뒤 다시 시도하세요."

  log "호스트 정지: 컨테이너 중지 -> docker/containerd 중지 -> umount /data"
  ssh "${SSH_OPTS[@]}" "$host" 'sudo bash -s' <<'REMOTE' || die "호스트 정지 실패. 볼륨이 마운트된 상태로 detach 하면 파일시스템이 깨지므로 중단합니다."
set -u
docker ps -q 2>/dev/null | xargs -r docker stop -t 30 >/dev/null 2>&1 || true
systemctl stop docker.socket docker containerd 2>/dev/null || true
sync

# 하위 마운트를 깊은 것부터 떼어낸 뒤 /data 자신을 뗍니다.
# -l(--list) 이 반드시 필요합니다. -R 만 쓰면 파이프로 넘겨도 트리 문자(└─)가
# 앞에 붙어 나와서 umount 가 전부 "no mount point specified" 로 실패합니다.
unmount_data() {
  findmnt -Rlno TARGET /data 2>/dev/null | tac | xargs -r -n1 umount || true
}

if mountpoint -q /data; then
  unmount_data
  if mountpoint -q /data; then
    fuser -km /data 2>/dev/null || true
    sleep 3
    unmount_data
  fi
fi

if mountpoint -q /data; then
  echo "umount /data 실패. 아직 잡고 있는 것:" >&2
  findmnt -Rlno TARGET /data >&2 || true
  fuser -vm /data >&2 2>&1 || true
  exit 1
fi
exit 0
REMOTE
}
