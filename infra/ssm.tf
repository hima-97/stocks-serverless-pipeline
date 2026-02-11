resource "aws_ssm_parameter" "massive_api_key" {
  name        = "/${local.name_prefix}/massive_api_key"
  description = "Massive API key for ${local.name_prefix} ingestion Lambda"
  type        = "SecureString"
  value       = var.massive_api_key
}
