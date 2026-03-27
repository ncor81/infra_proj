variable "app_name" {
    description = "Application name used to name AWS resources"
    type        = string
    default     = "infra_proj"
}

variable "aws_region" {
    description = "AWS region to deploy into"
    type        = string
    default     = "us-east-1"
}
