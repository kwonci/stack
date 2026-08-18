#!/usr/bin/env bash
# stack 을 끕니다. 02-compute 만 destroy 하므로 EBS 데이터 볼륨은 남습니다.
# DNS 는 Cloudflare 에 있어 이 stack 이 건드리지 않으므로 그대로입니다.
# 다만 터널은 인스턴스와 함께 사라지므로, 꺼져 있는 동안에는 SSH 도 Grafana 도
# 닿지 않습니다(공개 서비스가 502 가 되는 것과 같습니다). 다시 켜려면 make up.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TF_VAR_tfstate_bucket="$(tfstate_bucket)"
export TF_VAR_tfstate_bucket

quiesce_host

log "02-compute destroy"
tf 02-compute destroy -input=false -auto-approve

log "완료. 데이터 볼륨과 DNS 는 유지됩니다."
