# If massive_api_key is NOT provided, we read the existing parameter value so
# terraform plan/apply can run for unrelated changes without requiring the secret again.
#
# On a brand-new deployment where the parameter does not exist yet, the user MUST
# provide var.massive_api_key once to seed it.

data "aws_ssm_parameter" "massive_api_key_existing" {
  count           = var.massive_api_key == null ? 1 : 0
  name            = "/${local.name_prefix}/massive_api_key"
  with_decryption = true
}

resource "aws_ssm_parameter" "massive_api_key" {
  name        = "/${local.name_prefix}/massive_api_key"
  description = "Massive API key for ${local.name_prefix} ingestion Lambda"
  type        = "SecureString"

  # If user provides a key, use it (initial seed).
  # Otherwise, reuse the existing parameter value (so plan/apply works without re-supplying the secret).
  value = var.massive_api_key != null ? var.massive_api_key : data.aws_ssm_parameter.massive_api_key_existing[0].value

  lifecycle {
    # Prevent Terraform from overwriting rotated secrets after initial seeding.
    ignore_changes = [value]
  }
}
