# This file is responsible for setting up the API Gateway and connecting it to our Lambda function. 
# It also includes the necessary permissions for API Gateway to invoke the Lambda.

resource "aws_api_gateway_rest_api" "stocks_api" {
  name = "${local.name_prefix}-api"
}

resource "aws_api_gateway_resource" "movers" {
  rest_api_id = aws_api_gateway_rest_api.stocks_api.id
  parent_id   = aws_api_gateway_rest_api.stocks_api.root_resource_id
  path_part   = "movers"
}

resource "aws_api_gateway_method" "get_movers" {
  rest_api_id   = aws_api_gateway_rest_api.stocks_api.id
  resource_id   = aws_api_gateway_resource.movers.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "get_movers" {
  rest_api_id             = aws_api_gateway_rest_api.stocks_api.id
  resource_id             = aws_api_gateway_resource.movers.id
  http_method             = aws_api_gateway_method.get_movers.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.get_movers.invoke_arn
}

resource "aws_lambda_permission" "allow_apigw_invoke_get_movers" {
  statement_id  = "AllowAPIGatewayInvokeGetMovers"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_movers.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.stocks_api.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "stocks_api" {
  rest_api_id = aws_api_gateway_rest_api.stocks_api.id

  triggers = {
    redeploy = sha1(jsonencode({
      get_movers_integration = aws_api_gateway_integration.get_movers.id
      get_movers_method      = aws_api_gateway_method.get_movers.id
      resource               = aws_api_gateway_resource.movers.id
    }))
  }

  depends_on = [
    aws_api_gateway_integration.get_movers
  ]
}


resource "aws_api_gateway_stage" "dev" {
  rest_api_id   = aws_api_gateway_rest_api.stocks_api.id
  deployment_id = aws_api_gateway_deployment.stocks_api.id
  stage_name    = var.environment
}
