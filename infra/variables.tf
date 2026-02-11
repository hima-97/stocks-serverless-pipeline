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

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}


variable "massive_base_url" {
  description = "Base URL for Massive API"
  type        = string
  default     = "https://api.massive.com"
}

variable "massive_api_key" {
  description = "Massive API key (DO NOT COMMIT)."
  type        = string
  sensitive   = true
}

# Rate-limit / resilience knobs
variable "request_spacing_seconds" {
  description = "Delay between ticker calls to avoid RPM throttling"
  type        = number
  default     = 1.0
}

variable "max_attempts" {
  description = "Max attempts per ticker for retryable errors"
  type        = number
  default     = 4
}

variable "base_backoff_seconds" {
  description = "Base backoff for retries (429/5xx), exponential"
  type        = number
  default     = 15
}

variable "max_backoff_seconds" {
  description = "Max backoff cap for retries"
  type        = number
  default     = 45
}

variable "ingest_schedule_expression" {
  description = "EventBridge schedule expression (cron or rate). EventBridge cron uses UTC."
  type        = string
}

variable "allowed_account_ids" {
  description = "List of AWS account IDs Terraform is allowed to operate in"
  type        = list(string)
}