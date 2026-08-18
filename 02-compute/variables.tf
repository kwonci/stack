variable "project" {
  type = string
}

variable "region" {
  type = string
}

variable "tfstate_bucket" {
  description = "01-foundation 의 출력을 읽어올 state 버킷"
  type        = string
}

variable "instance_type" {
  type = string
}

variable "instance_arch" {
  description = "AMI 아키텍처. instance_type 과 반드시 맞아야 합니다 (t4g.* -> arm64)"
  type        = string

  validation {
    condition     = contains(["arm64", "amd64"], var.instance_arch)
    error_message = "instance_arch 는 arm64 또는 amd64 여야 합니다."
  }
}

variable "root_volume_size" {
  type = number
}

# 터널 토큰은 변수가 아닙니다. 01-foundation 의 remote state 에서 읽습니다 —
# 대시보드에서 복사해 오는 수작업을 없애기 위해서입니다.
#
# 다만 토큰이 user_data 를 거쳐 호스트로 가므로 terraform state 와 IMDS 양쪽에
# 남는 사실은 그대로입니다. metadata_options 의 hop_limit 1 이 컨테이너에서의
# IMDS 접근을 막지만, 호스트 root 를 잡힌 경우엔 읽힙니다.
