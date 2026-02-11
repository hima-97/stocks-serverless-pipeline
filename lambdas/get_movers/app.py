import os
import json
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")


def _to_jsonable(x):
    """DynamoDB returns Decimal for numbers; JSON can't serialize Decimal."""
    if isinstance(x, list):
        return [_to_jsonable(v) for v in x]
    if isinstance(x, dict):
        return {k: _to_jsonable(v) for k, v in x.items()}
    if isinstance(x, Decimal):
        return float(x)
    return x


def _resp(status_code: int, body_obj):
    # CORS now so Step 2 (API Gateway) + Step 4 (Frontend) work cleanly.
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,Authorization,X-Amz-Date,X-Api-Key,X-Amz-Security-Token",
            "Access-Control-Allow-Methods": "GET,OPTIONS",
        },
        "body": json.dumps(body_obj),
    }


def _public_item(item: dict) -> dict:
    """
    Return only the fields required by the API contract / PDF.
    """
    return {
        "Date": item.get("Date"),
        "Ticker": item.get("Ticker"),
        "PercentChange": item.get("PercentChange"),
        "ClosingPrice": item.get("ClosingPrice"),
    }


def handler(event, context):
    table_name = os.environ.get("TABLE_NAME")
    if not table_name:
        return _resp(500, {"error": "Missing TABLE_NAME env var"})

    table = dynamodb.Table(table_name)

    try:
        out = table.query(
            KeyConditionExpression=Key("pk").eq("MOVERS"),
            ScanIndexForward=False,  # newest first
            Limit=7,
        )

        items = out.get("Items", [])

        # Only expose fields required by the project spec
        public_items = [_public_item(item) for item in items]

        return _resp(200, _to_jsonable(public_items))

    except Exception as e:
        return _resp(500, {"error": str(e)})
