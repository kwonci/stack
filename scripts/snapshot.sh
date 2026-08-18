#!/usr/bin/env bash
# 데이터 볼륨 스냅샷을 즉시 하나 만듭니다.
# final_snapshot 은 destroy 할 때만 찍히므로, 평소 백업은 이게 유일합니다.
# 파일시스템 정합성을 위해 컨테이너를 멈추지는 않습니다 — 대부분의 경우
# 충분하지만, 확실히 하려면 make down 직후에 실행하세요(볼륨이 언마운트된 상태).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VOLUME_ID="$(tf 01-foundation output -raw data_volume_id)"

log "스냅샷 생성: $VOLUME_ID"
aws ec2 create-snapshot \
  --volume-id "$VOLUME_ID" \
  --description "$PROJECT manual snapshot" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$PROJECT-data},{Key=Project,Value=$PROJECT}]" \
  --query '[SnapshotId,State]' --output text

echo
log "이 stack 의 스냅샷 (되돌리려면 make down && make destroy-data 후 DATA_SNAPSHOT_ID 에 지정):"
list_snapshots
