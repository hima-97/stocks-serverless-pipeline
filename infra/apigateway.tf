# This file is responsible for setting up the API Gateway and connecting it to our Lambda function.
# It also includes the necessary permissions for API Gateway to invoke the Lambda.
# Additionally, it implements CORS preflight (OPTIONS) so browser clients can call the API reliably.

resource "aws_api_gateway_rest_api" "stocks_api" {
  name = "${local.name_prefix}-api"
}

resource "aws_api_gateway_resource" "movers" {
  rest_api_id = aws_api_gateway_rest_api.stocks_api.id
  parent_id   = aws_api_gateway_rest_api.stocks_api.root_resource_id
  path_part   = "movers"
}

# -------------------------
# GET /movers -> Lambda proxy
# -------------------------
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

# -------------------------
# CORS Preflight: OPTIONS /movers (MOCK)
# -------------------------
resource "aws_api_gateway_method" "options_movers" {
  rest_api_id   = aws_api_gateway_rest_api.stocks_api.id
  resource_id   = aws_api_gateway_resource.movers.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_movers" {
  rest_api_id = aws_api_gateway_rest_api.stocks_api.id
  resource_id = aws_api_gateway_resource.movers.id
  http_method = aws_api_gateway_method.options_movers.http_method

  type = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "options_movers_200" {
  rest_api_id = aws_api_gateway_rest_api.stocks_api.id
  resource_id = aws_api_gateway_resource.movers.id
  http_method = aws_api_gateway_method.options_movers.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Max-Age"       = true
  }
}

resource "aws_api_gateway_integration_response" "options_movers_200" {
  rest_api_id = aws_api_gateway_rest_api.stocks_api.id
  resource_id = aws_api_gateway_resource.movers.id
  http_method = aws_api_gateway_method.options_movers.http_method
  status_code = aws_api_gateway_method_response.options_movers_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization,X-Amz-Date,X-Api-Key,X-Amz-Security-Token'"
    "method.response.header.Access-Control-Max-Age"       = "'3600'"
  }

  depends_on = [
    aws_api_gateway_integration.options_movers,
    aws_api_gateway_method_response.options_movers_200,
  ]
}

# -------------------------
# Deployment + Stage
# Redeploy trigger includes both GET and OPTIONS resources
# -------------------------
resource "aws_api_gateway_deployment" "stocks_api" {
  rest_api_id = aws_api_gateway_rest_api.stocks_api.id

  triggers = {
    redeploy = sha1(jsonencode({
      resource = aws_api_gateway_resource.movers.id

      get_movers_method      = aws_api_gateway_method.get_movers.id
      get_movers_integration = aws_api_gateway_integration.get_movers.id

      options_movers_method               = aws_api_gateway_method.options_movers.id
      options_movers_integration          = aws_api_gateway_integration.options_movers.id
      options_movers_method_response      = aws_api_gateway_method_response.options_movers_200.id
      options_movers_integration_response = aws_api_gateway_integration_response.options_movers_200.id
    }))
  }

  # Ensures new deployment is created and stage is moved before old deployment is destroyed.
  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.get_movers,
    aws_api_gateway_integration_response.options_movers_200,
  ]
}

resource "aws_api_gateway_stage" "dev" {
  rest_api_id   = aws_api_gateway_rest_api.stocks_api.id
  deployment_id = aws_api_gateway_deployment.stocks_api.id
  stage_name    = var.environment
}
