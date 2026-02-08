output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.top_movers.name
}

output "lambda_role_arn" {
  value = aws_iam_role.lambda_exec_role.arn
}

output "get_movers_function_name" {
  value = aws_lambda_function.get_movers.function_name
}

output "get_movers_role_arn" {
  value = aws_iam_role.get_movers_role.arn
}

output "movers_endpoint" {
  value = "${aws_api_gateway_stage.dev.invoke_url}/movers"
}
