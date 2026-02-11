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
      TABLE_NAME       = aws_dynamodb_table.top_movers.name
      MASSIVE_BASE_URL = "https://api.massive.com"
      MASSIVE_API_KEY  = var.massive_api_key

      # Pacing: safe default to avoid RPM limits (6 calls ≈ 62.5 seconds + network/retry time)
      REQUEST_SPACING_SECONDS = "12.5"

      # Retry controls (bounded)
      MAX_ATTEMPTS             = "4"
      BASE_429_BACKOFF_SECONDS = "2"
      BASE_5XX_BACKOFF_SECONDS = "0.5"
      MAX_BACKOFF_SECONDS      = "10"
    }
  }
}
