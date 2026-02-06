resource "aws_dynamodb_table" "top_movers" {
  name         = "${var.project_name}-${var.environment}-top-movers"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "pk"
  range_key = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  tags = local.common_tags
}
