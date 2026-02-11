# ------------------------------------------------------------
# Massive API Key (SSM Parameter Store)
# ------------------------------------------------------------
# Behavior:
# - First deployment: you must provide var.massive_api_key once to seed SSM
# - Later plans/applies: Terraform reuses the existing SSM value (no need to re-supply secret)
# - Terraform will NOT overwrite rotated secrets (ignore_changes)
# ------------------------------------------------------------

data "aws_ssm_parameter" "massive_api_key_existing" {
  count           = var.massive_api_key == null ? 1 : 0
  name            = "/${local.name_prefix}/massive_api_key"
  with_decryption = true
}

resource "aws_ssm_parameter" "massive_api_key" {
  name        = "/${local.name_prefix}/massive_api_key"
  description = "Massive API key for ${local.name_prefix} ingestion Lambda"
  type        = "SecureString"

  # Seed if provided; otherwise reuse the existing value so plan/apply works without the secret.
  value = var.massive_api_key != null ? var.massive_api_key : data.aws_ssm_parameter.massive_api_key_existing[0].value

  lifecycle {
    # Prevent Terraform from overwriting rotated secrets
    ignore_changes = [value]
  }
}
