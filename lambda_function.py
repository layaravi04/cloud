import json
import os
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

REGION = "us-west-2"
TABLE_NAME = os.environ.get("TABLE_NAME", "OrdersTable")

_table = None


class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            if obj % 1 == 0:
                return int(obj)
            return float(obj)
        return super().default(obj)


def get_table():
    global _table
    if _table is None:
        _table = boto3.resource("dynamodb").Table(TABLE_NAME)
    return _table


def lambda_handler(event, context):
    method, path, body, path_params, query = parse_event(event)

    if method == "OPTIONS":
        return respond(200, {"ok": True})

    if method == "GET" and is_health_path(path):
        return respond(200, {"status": "healthy", "region": REGION})

    if method == "POST" and is_orders_path(path):
        return create_order(body)

    if method == "GET":
        order_id = extract_order_id(path, path_params, query)
        if order_id:
            return get_order(order_id)

    return respond(
        400,
        {
            "error": "Unsupported request",
            "method": method,
            "path": path,
            "region": REGION,
        },
    )


def create_order(body):
    if not isinstance(body, dict):
        return respond(400, {"error": "Request body must be JSON"})

    order_id = body.get("orderId") or body.get("order_id")
    if not order_id:
        return respond(400, {"error": "orderId is required"})

    quantity = body.get("quantity", 1)
    try:
        quantity = int(quantity)
    except (TypeError, ValueError):
        quantity = 1

    item = {
        "orderId": str(order_id),
        "customerId": str(body.get("customerId") or body.get("customer_id") or ""),
        "productId": str(body.get("productId") or body.get("product_id") or ""),
        "quantity": quantity,
        "status": str(body.get("status") or "created"),
        "originRegion": REGION,
    }

    try:
        get_table().put_item(Item=item)
    except ClientError as exc:
        return respond(500, {"error": "Failed to create order", "detail": str(exc)})

    return respond(201, {"message": "Order created", "order": item, "region": REGION})


def get_order(order_id):
    try:
        result = get_table().get_item(Key={"orderId": str(order_id)})
    except ClientError as exc:
        return respond(500, {"error": "Failed to retrieve order", "detail": str(exc)})

    item = result.get("Item")
    if not item:
        return respond(404, {"error": "Order not found", "orderId": order_id})

    return respond(200, {"order": item, "region": REGION})


def parse_event(event):
    event = event or {}
    http = (event.get("requestContext") or {}).get("http") or {}

    method = (
        event.get("httpMethod")
        or event.get("method")
        or http.get("method")
        or "GET"
    ).upper()

    path = event.get("path") or event.get("rawPath") or http.get("path") or "/"
    path_params = event.get("pathParameters") or {}
    query = event.get("queryStringParameters") or {}

    body = event.get("body")
    if isinstance(body, str) and body:
        try:
            body = json.loads(body)
        except json.JSONDecodeError:
            body = {}

    return method, path, body, path_params, query


def is_health_path(path):
    normalized = (path or "/").rstrip("/") or "/"
    return normalized == "/health" or normalized.endswith("/health")


def is_orders_path(path):
    normalized = (path or "/").rstrip("/") or "/"
    return normalized in ("/", "/orders", "/order")


def extract_order_id(path, path_params, query):
    if path_params:
        for key in ("orderId", "order_id", "id"):
            if path_params.get(key):
                return path_params[key]

    if query:
        for key in ("orderId", "order_id", "id"):
            if query.get(key):
                return query[key]

    parts = [part for part in (path or "").split("/") if part]
    if len(parts) >= 2 and parts[-2] in ("orders", "order"):
        return parts[-1]
    return None


def respond(status_code, payload):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "content-type",
            "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
        },
        "body": json.dumps(payload, cls=DecimalEncoder),
    }
