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
  name               = "${var.project_name}-${var.environment}-lambda-exec-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = local.common_tags
}

# Basic logging to CloudWatch (so Lambda can write logs)
resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Custom policy: allow DynamoDB access on our table only
data "aws_iam_policy_document" "dynamodb_access" {
  statement {
    effect = "Allow"

    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem"
    ]

    resources = [
      aws_dynamodb_table.top_movers.arn
    ]
  }
}

resource "aws_iam_policy" "lambda_dynamodb_policy" {
  name   = "${var.project_name}-${var.environment}-lambda-dynamodb-policy"
  policy = data.aws_iam_policy_document.dynamodb_access.json
  tags   = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb_attach" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.lambda_dynamodb_policy.arn
}

resource "aws_iam_role" "get_movers_role" {
  name = "${var.project_name}-${var.environment}-get-movers-role"

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
  name = "${var.project_name}-${var.environment}-get-movers-ddb"

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
