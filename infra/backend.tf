terraform {
    required_version = ">= 1.10"
    backend "s3" {
        bucket          = "iam-dev-tf-state-952165815395"
        key             = "prod/terraform.tfstate"
        region          = "us-east-1"
        use_lockfile    = true
        encrypt         = true
    }
}
