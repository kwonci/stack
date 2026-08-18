#!/usr/bin/env bash
# apply 하지 않고 01/02 의 변경분만 확인합니다. (00-global 은 bootstrap 소관)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TF_VAR_tfstate_bucket="$(tfstate_bucket)"
export TF_VAR_tfstate_bucket

for layer in 01-foundation 02-compute; do
  log "$layer"
  tf "$layer" plan -input=false
done
