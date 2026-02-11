data "archive_file" "get_movers_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/get_movers"
  output_path = "${path.module}/../dist/get_movers.zip"
}

resource "aws_lambda_function" "get_movers" {
  function_name = "${local.name_prefix}-get-movers"
  role          = aws_iam_role.get_movers_role.arn
  handler       = "app.handler"
  runtime       = "python3.12"

  filename         = data.archive_file.get_movers_zip.output_path
  source_code_hash = data.archive_file.get_movers_zip.output_base64sha256

  memory_size = 128
  timeout     = 15

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.top_movers.name
    }
  }
}
