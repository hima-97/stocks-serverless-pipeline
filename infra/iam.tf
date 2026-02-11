# AWS-managed KMS key used by SSM Parameter Store SecureString by default
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

# -----------------------------
# Shared Lambda assume role doc
# -----------------------------
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

# -----------------------------
# Ingestion Lambda Role
# -----------------------------
resource "aws_iam_role" "lambda_exec_role" {
  name               = "${local.name_prefix}-lambda-exec-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# Basic logging to CloudWatch
resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# DynamoDB access for ingestion Lambda (table only)
data "aws_iam_policy_document" "ingest_dynamodb_access" {
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

resource "aws_iam_policy" "ingest_dynamodb_policy" {
  name   = "${local.name_prefix}-ingest-ddb"
  policy = data.aws_iam_policy_document.ingest_dynamodb_access.json
}

resource "aws_iam_role_policy_attachment" "ingest_dynamodb_attach" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.ingest_dynamodb_policy.arn
}

# SSM + KMS decrypt access for ingestion Lambda (Massive API key)
# Requires aws_ssm_parameter.massive_api_key to exist (infra/ssm.tf)
data "aws_iam_policy_document" "ingest_ssm_kms_access" {
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
    ]
    resources = [
      aws_ssm_parameter.massive_api_key.arn,
    ]
  }

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

resource "aws_iam_policy" "ingest_ssm_kms_policy" {
  name   = "${local.name_prefix}-ingest-ssm-kms"
  policy = data.aws_iam_policy_document.ingest_ssm_kms_access.json
}

resource "aws_iam_role_policy_attachment" "ingest_ssm_kms_attach" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.ingest_ssm_kms_policy.arn
}

# -----------------------------
# Retrieval Lambda Role (GET /movers)
# -----------------------------
resource "aws_iam_role" "get_movers_role" {
  name               = "${local.name_prefix}-get-movers-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "get_movers_basic_logs" {
  role       = aws_iam_role.get_movers_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# DynamoDB Query access for retrieval Lambda (table only)
data "aws_iam_policy_document" "get_movers_ddb_access" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:Query",
    ]
    resources = [
      aws_dynamodb_table.top_movers.arn,
    ]
  }
}

resource "aws_iam_policy" "get_movers_ddb_policy" {
  name   = "${local.name_prefix}-get-movers-ddb"
  policy = data.aws_iam_policy_document.get_movers_ddb_access.json
}

resource "aws_iam_role_policy_attachment" "get_movers_ddb_attach" {
  role       = aws_iam_role.get_movers_role.name
  policy_arn = aws_iam_policy.get_movers_ddb_policy.arn
}
