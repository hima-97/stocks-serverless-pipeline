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

# ----------------------------------------------------
# Massive API Key
# ----------------------------------------------------
# Used only to initially seed SSM Parameter Store.
# After SSM exists, Terraform does not require this.  (Note: fixed in a later improvement by adding ignore_changes)
# Default = null prevents interactive prompts.
variable "massive_api_key" {
  description = "Massive API key (used only to seed SSM Parameter Store)."
  type        = string
  sensitive   = true
  default     = null
}

# ----------------------------------------------------
# Rate-limit / resilience knobs (wired into ingest Lambda env vars)
# ----------------------------------------------------
variable "request_spacing_seconds" {
  description = "Delay between ticker calls to avoid RPM throttling"
  type        = number
  default     = 12.5
}

variable "max_attempts" {
  description = "Max attempts per ticker for retryable errors"
  type        = number
  default     = 4
}

variable "base_backoff_seconds" {
  description = "Base backoff (seconds) for Massive throttling (HTTP 429), exponential"
  type        = number
  default     = 2
}

variable "base_5xx_backoff_seconds" {
  description = "Base backoff (seconds) for transient Massive/API failures (HTTP 5xx), exponential"
  type        = number
  default     = 0.5
}

variable "max_backoff_seconds" {
  description = "Max backoff cap (seconds) for retries"
  type        = number
  default     = 10
}

# ----------------------------------------------------
# Scheduling (EventBridge)
# ----------------------------------------------------
variable "ingest_schedule_expression" {
  description = "EventBridge schedule expression (cron or rate). EventBridge cron uses UTC."
  type        = string
  default     = "cron(30 0 * * ? *)"

  validation {
    condition = (
      can(regex("^cron\\(.+\\)$", var.ingest_schedule_expression)) ||
      can(regex("^rate\\(.+\\)$", var.ingest_schedule_expression))
    )
    error_message = "ingest_schedule_expression must start with cron(...) or rate(...)."
  }
}

# ----------------------------------------------------
# Safety guard
# ----------------------------------------------------
# Empty list = no account restriction.
# If you want enforcement, provide IDs explicitly.
variable "allowed_account_ids" {
  description = "List of AWS account IDs Terraform is allowed to operate in"
  type        = list(string)
  default     = []
}
