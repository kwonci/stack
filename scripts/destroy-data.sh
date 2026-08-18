#!/usr/bin/env bash
# 데이터 볼륨만 파괴합니다. 스냅샷에서 되돌릴 때 쓰는 단계입니다.
# final_snapshot 이 켜져 있으므로 파괴 직전 상태의 스냅샷이 하나 남습니다.
#
#   make down && make destroy-data
#   .env 의 DATA_SNAPSHOT_ID 에 되돌릴 스냅샷 ID 를 넣고
#   make up
#   복구가 끝나면 DATA_SNAPSHOT_ID 를 다시 비웁니다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TF_VAR_tfstate_bucket="$(tfstate_bucket)"
export TF_VAR_tfstate_bucket

if instance_exists; then
  die "인스턴스가 아직 살아 있습니다. make down 을 먼저 실행하세요."
fi

VOLUME_ID="$(tf 01-foundation output -raw data_volume_id)"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

echo
echo "  대상: $VOLUME_ID"
echo "  stack: $PROJECT ($DOMAIN)"
echo "  계정/리전: $ACCOUNT / $AWS_REGION"
echo
echo "되돌릴 수 있는 스냅샷:"
list_snapshots
echo

read -rp "계속하려면 'destroy' 를 입력하세요: " answer
[ "$answer" = "destroy" ] || die "취소했습니다"

tf 01-foundation destroy -input=false -auto-approve -target=aws_ebs_volume.data

echo
log "완료. 되돌릴 스냅샷 목록:"
list_snapshots
echo
echo "  다음 단계: .env 의 DATA_SNAPSHOT_ID 에 위 ID 중 하나를 넣고 make up."
echo "  비워둔 채로 make up 하면 빈 볼륨이 생기고, 그러면 다시 여기로 와야 합니다."
echo "  (terraform 이 남긴 '변경이 불완전할 수 있음' 경고는 -target 사용 시 정상입니다.)"
