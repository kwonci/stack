terraform {
  backend "s3" {
    key = "02-compute/terraform.tfstate"
  }
}
