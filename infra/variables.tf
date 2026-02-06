variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Project name for tagging and naming"
  type        = string
  default     = "stocks-serverless-pipeline"
}

variable "environment" {
  description = "Environment name (dev/prod)"
  type        = string
  default     = "dev"
}

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
