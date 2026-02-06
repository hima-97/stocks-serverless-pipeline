output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.top_movers.name
}

output "lambda_role_arn" {
  value = aws_iam_role.lambda_exec_role.arn
}
