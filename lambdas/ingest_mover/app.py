import json
import os
import random
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP

import boto3
from botocore.exceptions import ClientError

WATCHLIST = ["AAPL", "MSFT", "GOOGL", "AMZN", "TSLA", "NVDA"]

_ssm = boto3.client("ssm")
_cached_api_key = None


def _get_massive_api_key() -> str:
    """Fetch Massive API key from SSM Parameter Store (SecureString). Cache across warm invocations."""
    global _cached_api_key
    if _cached_api_key:
        return _cached_api_key

    param_name = os.environ.get("MASSIVE_API_KEY_PARAM")
    if not param_name:
        raise RuntimeError("Missing env var MASSIVE_API_KEY_PARAM")

    resp = _ssm.get_parameter(Name=param_name, WithDecryption=True)
    _cached_api_key = resp["Parameter"]["Value"]
    return _cached_api_key


def _get_env(name: str, default: str | None = None) -> str:
    v = os.environ.get(name, default)
    if v is None or v == "":
        raise RuntimeError(f"Missing required environment variable: {name}")
    return v


def _sleep_jitter(seconds: float) -> None:
    # small jitter helps avoid synchronized retries
    time.sleep(max(0.0, seconds) + random.uniform(0.0, 0.25))


def _to_ddb_number(x: float, places: int = 6) -> Decimal:
    q = Decimal("1." + ("0" * places))
    return Decimal(str(x)).quantize(q, rounding=ROUND_HALF_UP)


class SmoothRateLimiter:
    """
    Ensures at least min_interval seconds between outbound API calls.
    We pace requests to avoid rate limiting.
    """

    def __init__(self, min_interval_seconds: float):
        self.min_interval = max(0.0, float(min_interval_seconds))
        self.next_allowed = time.time()

    def acquire(self):
        now = time.time()
        if now < self.next_allowed:
            _sleep_jitter(self.next_allowed - now)
        now2 = time.time()
        self.next_allowed = now2 + self.min_interval


def _fetch_json(url: str, timeout_seconds: int = 15) -> dict:
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout_seconds) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _fetch_json_with_retries(url: str) -> dict:
    max_attempts = int(_get_env("MAX_ATTEMPTS", "4"))
    base_429 = float(_get_env("BASE_429_BACKOFF_SECONDS", "2"))
    base_5xx = float(_get_env("BASE_5XX_BACKOFF_SECONDS", "0.5"))
    max_backoff = float(_get_env("MAX_BACKOFF_SECONDS", "10"))

    last_err: Exception | None = None

    for attempt in range(1, max_attempts + 1):
        try:
            return _fetch_json(url, timeout_seconds=15)

        except urllib.error.HTTPError as e:
            status = e.code
            try:
                body = e.read().decode("utf-8")
            except Exception:
                body = ""

            last_err = RuntimeError(f"HTTPError {status} from Massive. Body={body}")

            # 429: Retry-After is missing, so do bounded exp backoff + jitter.
            if status == 429 and attempt < max_attempts:
                print(f"[WARN] 429 for {url} attempt {attempt}, backing off")
                sleep_s = min(max_backoff, base_429 * (2 ** (attempt - 1)))
                _sleep_jitter(sleep_s)
                continue

            # 5xx: also retry
            if status in (500, 502, 503, 504) and attempt < max_attempts:
                sleep_s = min(max_backoff, base_5xx * (2 ** (attempt - 1)))
                _sleep_jitter(sleep_s)
                continue

            raise last_err

        except Exception as e:
            last_err = e
            if attempt < max_attempts:
                sleep_s = min(max_backoff, base_5xx * (2 ** (attempt - 1)))
                _sleep_jitter(sleep_s)
                continue
            raise

    raise last_err if last_err else RuntimeError("Unknown error fetching Massive JSON")


def _fetch_prev_day_open_close(symbol: str, api_key: str) -> tuple[str, float, float]:
    base_url = _get_env("MASSIVE_BASE_URL").rstrip("/")
    url = f"{base_url}/v2/aggs/ticker/{symbol}/prev?adjusted=true&apiKey={api_key}"

    data = _fetch_json_with_retries(url)
    if data.get("status") != "OK" or not data.get("results"):
        raise RuntimeError(f"No results for {symbol}: {data}")

    r0 = data["results"][0]
    open_price = float(r0["o"])
    close_price = float(r0["c"])

    ts_ms = int(r0["t"])
    dt = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc)
    date_str = dt.strftime("%Y-%m-%d")

    return date_str, open_price, close_price


def _percent_change(open_price: float, close_price: float) -> float:
    if open_price == 0:
        raise RuntimeError("Open price is 0; cannot compute percent change")
    return ((close_price - open_price) / open_price) * 100.0


def handler(event, context):
    table_name = _get_env("TABLE_NAME")
    api_key = _get_massive_api_key()

    # Stable default: 12.5s spacing => 6 calls ~ 62.5s (helps avoid RPM caps)
    spacing_s = float(_get_env("REQUEST_SPACING_SECONDS", "12.5"))
    limiter = SmoothRateLimiter(spacing_s)

    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(table_name)

    # --- Step 1: Make ONE request to learn trading_date, then short-circuit if already stored ---
    limiter.acquire()
    trading_date, o0, c0 = _fetch_prev_day_open_close(WATCHLIST[0], api_key)

    try:
        existing = table.get_item(Key={"pk": "MOVERS", "sk": trading_date}).get("Item")
    except ClientError as e:
        raise RuntimeError(f"DynamoDB get_item failed: {e}")

    if existing:
        return {
            "statusCode": 200,
            "body": json.dumps(
                {
                    "stored": False,
                    "cached": True,
                    "message": "already_stored",
                    "tradingDate": trading_date,
                    "item": {
                        "pk": existing["pk"],
                        "sk": existing["sk"],
                        "Date": existing["Date"],
                        "Ticker": existing["Ticker"],
                        "PercentChange": float(existing["PercentChange"]),
                        "ClosingPrice": float(existing["ClosingPrice"]),
                    },
                    # No full watchlist fetch happened on this path.
                    "successCount": 0,
                    "failureCount": 0,
                    "failures": [],
                }
            ),
        }


    # --- Step 2: Not stored yet → fetch ALL 6 (all-or-nothing) ---
    successes = []
    failures = []

    pct0 = _percent_change(o0, c0)
    successes.append(
        {
            "Ticker": WATCHLIST[0],
            "PercentChange": round(pct0, 6),
            "ClosingPrice": round(c0, 6),
        }
    )

    for ticker in WATCHLIST[1:]:
        try:
            limiter.acquire()
            date_str, o, c = _fetch_prev_day_open_close(ticker, api_key)

            if date_str != trading_date:
                raise RuntimeError(f"Date mismatch: expected {trading_date}, got {date_str}")

            pct = _percent_change(o, c)
            successes.append(
                {
                    "Ticker": ticker,
                    "PercentChange": round(pct, 6),
                    "ClosingPrice": round(c, 6),
                }
            )

        except Exception as e:
            failures.append({"Ticker": ticker, "Error": str(e)})

    if failures:
        raise RuntimeError(f"One or more tickers failed; refusing to store. failures={failures}")

    top = None
    for c in successes:
        if top is None or abs(c["PercentChange"]) > abs(top["PercentChange"]):
            top = c

    if top is None:
        raise RuntimeError("Unexpected: no top mover computed")

    item = {
        "pk": "MOVERS",
        "sk": trading_date,
        "Date": trading_date,
        "Ticker": top["Ticker"],
        "PercentChange": _to_ddb_number(top["PercentChange"]),
        "ClosingPrice": _to_ddb_number(top["ClosingPrice"]),
    }

    stored = True
    try:
        table.put_item(
            Item=item,
            ConditionExpression="attribute_not_exists(pk) AND attribute_not_exists(sk)",
        )
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            stored = False
        else:
            raise

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "stored": stored,
                "cached": False,
                "item": {
                    **item,
                    "PercentChange": float(item["PercentChange"]),
                    "ClosingPrice": float(item["ClosingPrice"]),
                },
                "successCount": len(successes),
                "failureCount": 0,
                "failures": [],
            }
        ),
    }
