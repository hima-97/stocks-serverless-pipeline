data "archive_file" "ingest_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/ingest_mover"
  output_path = "${path.module}/../dist/ingest_mover.zip"
}

resource "aws_lambda_function" "ingest_mover" {
  function_name = "${local.name_prefix}-ingest-mover"
  role          = aws_iam_role.lambda_exec_role.arn
  runtime       = "python3.12"
  handler       = "app.handler"

  filename         = data.archive_file.ingest_zip.output_path
  source_code_hash = data.archive_file.ingest_zip.output_base64sha256

  memory_size = 128
  timeout     = 120

  environment {
    variables = {
      TABLE_NAME            = aws_dynamodb_table.top_movers.name
      MASSIVE_BASE_URL      = var.massive_base_url
      MASSIVE_API_KEY_PARAM = aws_ssm_parameter.massive_api_key.name

      # Pacing: avoid RPM throttling (configured via tfvars)
      REQUEST_SPACING_SECONDS = tostring(var.request_spacing_seconds)

      # Retry controls (bounded, configured via tfvars)
      MAX_ATTEMPTS             = tostring(var.max_attempts)
      BASE_429_BACKOFF_SECONDS = tostring(var.base_backoff_seconds)
      BASE_5XX_BACKOFF_SECONDS = tostring(var.base_5xx_backoff_seconds)
      MAX_BACKOFF_SECONDS      = tostring(var.max_backoff_seconds)
    }
  }
}
