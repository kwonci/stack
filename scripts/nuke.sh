#!/usr/bin/env bash
# 전부 파괴합니다. down 과 달리 데이터 볼륨까지 사라집니다.
#
#  - 데이터 볼륨은 final_snapshot 설정 때문에 스냅샷 하나를 남깁니다.
#    복구하려면 .env 의 DATA_SNAPSHOT_ID 에 그 스냅샷 ID 를 넣고 make up.
#    복구가 끝나면 DATA_SNAPSHOT_ID 를 다시 비우세요.
#  - Cloudflare 쪽(zone, 터널, Access 정책)은 아무것도 건드리지 않습니다.
#  - 00-global(state 버킷)은 건드리지 않습니다.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TF_VAR_tfstate_bucket="$(tfstate_bucket)"
export TF_VAR_tfstate_bucket

read -rp "정말 전부 파괴합니까? 'nuke' 를 입력하세요: " answer
[ "$answer" = "nuke" ] || die "취소했습니다"

quiesce_host

log "02-compute destroy"
tf 02-compute destroy -input=false -auto-approve

log "01-foundation destroy"
tf 01-foundation destroy -input=false -auto-approve

log "완료. 복구용 스냅샷 (DATA_SNAPSHOT_ID 에 넣으세요):"
list_snapshots
