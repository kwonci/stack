output "tfstate_bucket" {
  description = "01/02 레이어가 backend 로 쓰는 S3 버킷"
  value       = aws_s3_bucket.tfstate.id
}

output "region" {
  description = "사람이 조회용으로 씁니다. backend.hcl 은 bootstrap.sh 가 씁니다."
  value       = var.region
}
