terraform {
  required_version = ">= 1.10"
  backend "s3" {
    bucket       = "iam-dev-tf-state-YOUR_ACCOUNT_ID"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
