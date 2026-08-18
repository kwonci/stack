# scripts/bootstrap.sh 가 첫 apply 이후 이 파일을 backend.tf 로 복사하고
# `terraform init -migrate-state` 로 로컬 state 를 S3 로 옮깁니다.
terraform {
  backend "s3" {
    key = "00-global/terraform.tfstate"
  }
}
