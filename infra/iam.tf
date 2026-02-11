# AWS-managed KMS key used by SSM Parameter Store SecureString by default
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda_exec_role" {
  name               = "${local.name_prefix}-lambda-exec-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# Basic logging to CloudWatch (so Lambda can write logs)
resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom policy: allow DynamoDB access on our table only (ingestion lambda)
data "aws_iam_policy_document" "dynamodb_access" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
    ]
    resources = [
      aws_dynamodb_table.top_movers.arn,
    ]
  }
}

resource "aws_iam_policy" "lambda_dynamodb_policy" {
  name   = "${local.name_prefix}-lambda-dynamodb-policy"
  policy = data.aws_iam_policy_document.dynamodb_access.json
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb_attach" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.lambda_dynamodb_policy.arn
}

# ---- Retrieval Lambda role (GET /movers) ----

resource "aws_iam_role" "get_movers_role" {
  name = "${local.name_prefix}-get-movers-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "get_movers_basic_logs" {
  role       = aws_iam_role.get_movers_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "get_movers_ddb_policy" {
  name = "${local.name_prefix}-get-movers-ddb"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:Query"]
      Resource = aws_dynamodb_table.top_movers.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "get_movers_ddb_attach" {
  role       = aws_iam_role.get_movers_role.name
  policy_arn = aws_iam_policy.get_movers_ddb_policy.arn
}

# ---- Ingestion Lambda extra access: read Massive API key from SSM Parameter Store ----
# Requires aws_ssm_parameter.massive_api_key to exist (in infra/ssm.tf)
data "aws_iam_policy_document" "ingest_extra_access" {
  # Read the SecureString parameter value
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
    ]
    resources = [
      aws_ssm_parameter.massive_api_key.arn,
    ]
  }

  # Decrypt SecureString using the default AWS-managed key for SSM Parameter Store
  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
    ]
    resources = [
      data.aws_kms_alias.ssm.target_key_arn,
    ]
  }
}

resource "aws_iam_role_policy" "ingest_extra_access" {
  name   = "${local.name_prefix}-ingest-ssm-access"
  role   = aws_iam_role.lambda_exec_role.id
  policy = data.aws_iam_policy_document.ingest_extra_access.json
}
