variable "project" {
  description = "stack 이름. 모든 리소스 이름의 prefix 로 쓰입니다."
  type        = string
}

variable "region" {
  description = "AWS 리전"
  type        = string
}
