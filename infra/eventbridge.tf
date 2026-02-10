# Runs the ingestion Lambda on a daily schedule.
# IMPORTANT: EventBridge cron is evaluated in UTC.

resource "aws_cloudwatch_event_rule" "daily_ingest" {
  name                = "${local.name_prefix}-daily-ingest"
  description         = "Run ingest_mover once per day"
  schedule_expression = var.ingest_schedule_expression
}

resource "aws_cloudwatch_event_target" "daily_ingest_target" {
  rule      = aws_cloudwatch_event_rule.daily_ingest.name
  target_id = "ingest-mover"
  arn       = aws_lambda_function.ingest_mover.arn
}

resource "aws_lambda_permission" "allow_eventbridge_invoke_ingest" {
  statement_id  = "AllowExecutionFromEventBridgeDailyRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest_mover.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_ingest.arn
}
