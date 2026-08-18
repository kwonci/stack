#!/usr/bin/env bash
# 최초 1회. tfstate 를 담을 S3 버킷을 만들고, 자기 자신의 state 를 그 버킷으로 옮깁니다.
# 이미 부트스트랩된 계정에서 다시 실행하면(새 머신에서 clone 한 경우 포함)
# backend.hcl 과 backend.tf 를 복원하고 00-global 만 다시 apply 합니다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${PROJECT}-tfstate-${ACCOUNT}"

# S3 이름공간은 전역이라 규칙으로 유추한 이름이 남의 계정 버킷일 수 있습니다.
# 소유자 확인 없이 backend 를 걸면 state 를 남의 버킷에 쓰게 됩니다.
#   0   = 내 소유
#   1   = 존재하지 않음
#   그 외 = 남의 것이거나 판단 불가 -> 중단
bucket_status() {
  local err
  if err="$(aws s3api head-bucket --bucket "$BUCKET" \
    --expected-bucket-owner "$ACCOUNT" 2>&1)"; then
    return 0
  fi
  case "$err" in
    *404* | *"Not Found"*) return 1 ;;
    *) die "버킷 $BUCKET 에 접근할 수 없거나 이 계정 소유가 아닙니다.
  남의 버킷이면 .env 의 PROJECT 를 바꾸고, 내 버킷이어야 한다면 IAM 권한과 자격증명을 확인하세요.
  $err" ;;
  esac
}

write_backend_hcl() {
  cat > "$ROOT/backend.hcl" <<EOF
bucket       = "$BUCKET"
region       = "$AWS_REGION"
encrypt      = true
use_lockfile = true
EOF
  log "backend.hcl 생성 (bucket=$BUCKET)"
}

# bootstrap 은 tf() 를 거치지 않고 terraform 을 직접 부르므로 여기서 씁니다.
write_tfvars 00-global "project=$PROJECT" "region=$AWS_REGION"

cd "$ROOT/00-global"

# 판단 기준은 버킷의 존재 여부입니다. backend.tf 는 gitignore 되어 있어
# 새로 clone 한 머신에는 없으므로, 그것으로 판단하면 이미 부트스트랩된
# 계정에서도 버킷을 다시 만들려다 실패합니다.
if bucket_status; then
  log "state 버킷이 이미 있습니다 ($BUCKET)"
  [ -f "$ROOT/backend.hcl" ] || write_backend_hcl
  # 소유자를 확인한 건 $BUCKET 인데 init 은 backend.hcl 이 가리키는 버킷을 씁니다.
  # 낡거나 손댄 backend.hcl 이면 검증하지 않은 버킷으로 state 가 나갑니다.
  [ "$(tfstate_bucket)" = "$BUCKET" ] ||
    die "backend.hcl 이 다른 버킷($(tfstate_bucket))을 가리킵니다. 예상: $BUCKET"
  [ -f backend.tf ] || command cp backend.tf.tpl backend.tf
  # 앞선 실행이 버킷은 만들고 migrate 전에 죽었다면 로컬 state 가 남아 있습니다.
  # 그걸 -reconfigure 로 덮으면 영영 되살릴 수 없으므로 migrate 로 살려냅니다.
  if [ -f terraform.tfstate ]; then
    log "중단된 부트스트랩 발견 — 로컬 state 를 S3 로 migrate 합니다"
    terraform init -input=false -force-copy -migrate-state -backend-config="$ROOT/backend.hcl" >/dev/null
    rm -f terraform.tfstate terraform.tfstate.backup
  else
    terraform init -input=false -reconfigure -backend-config="$ROOT/backend.hcl" >/dev/null
  fi
  terraform apply -input=false -auto-approve
  log "완료. 이제 make up 을 실행하세요."
  exit 0
fi

log "00-global 을 로컬 state 로 apply (state 버킷 생성)"
terraform init -input=false >/dev/null
terraform apply -input=false -auto-approve

write_backend_hcl

log "00-global 의 state 를 S3 로 migrate"
command cp backend.tf.tpl backend.tf
terraform init -input=false -force-copy -migrate-state -backend-config="$ROOT/backend.hcl"

rm -f terraform.tfstate terraform.tfstate.backup

log "완료. 이제 make up 을 실행하세요."
