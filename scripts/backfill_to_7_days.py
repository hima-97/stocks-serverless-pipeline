# This file is a standalone script to backfill the DynamoDB table with the last 7 full trading days of data, 
# as of a specified end date. It can be run from the command line and is idempotent (safe to re-run without creating duplicates).

import argparse
import json
import os
import random
import time
from datetime import datetime, timezone, timedelta
from decimal import Decimal, ROUND_HALF_UP

import boto3
import urllib3


WATCHLIST = ["AAPL", "MSFT", "GOOGL", "AMZN", "TSLA", "NVDA"]


def _require_env(name: str, default: str | None = None) -> str:
    v = os.environ.get(name, default)
    if v is None or v == "":
        raise RuntimeError(f"Missing required environment variable: {name}")
    return v


def _sleep_jitter(seconds: float) -> None:
    time.sleep(max(0.0, seconds) + random.uniform(0.0, 0.25))


class SmoothRateLimiter:
    def __init__(self, spacing_seconds: float):
        self.spacing = max(0.0, float(spacing_seconds))
        self.next_ok = time.time()

    def wait(self):
        now = time.time()
        if now < self.next_ok:
            _sleep_jitter(self.next_ok - now)
        self.next_ok = time.time() + self.spacing


def _to_ddb_number(x: float, places: int = 6) -> Decimal:
    q = Decimal("1." + ("0" * places))
    return Decimal(str(x)).quantize(q, rounding=ROUND_HALF_UP)


_cached_api_key = None


def _get_massive_api_key(aws_region: str) -> str:
    """
    Prefer SSM (MASSIVE_API_KEY_PARAM). Fallback to MASSIVE_API_KEY.
    """
    global _cached_api_key
    if _cached_api_key:
        return _cached_api_key

    # Preferred: SSM SecureString
    param_name = os.environ.get("MASSIVE_API_KEY_PARAM")
    if param_name:
        ssm = boto3.client("ssm", region_name=aws_region)
        resp = ssm.get_parameter(Name=param_name, WithDecryption=True)
        _cached_api_key = resp["Parameter"]["Value"]
        return _cached_api_key

    # Fallback: env var
    api_key = os.environ.get("MASSIVE_API_KEY")
    if api_key:
        _cached_api_key = api_key
        return _cached_api_key

    raise RuntimeError("Provide MASSIVE_API_KEY_PARAM (preferred) or MASSIVE_API_KEY (fallback).")


def _date_str_from_epoch_ms(ms: int) -> str:
    dt = datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc)
    return dt.strftime("%Y-%m-%d")


def _get_json(http: urllib3.PoolManager, url: str, max_attempts: int, max_backoff: float) -> dict:
    last_err = None
    for attempt in range(1, max_attempts + 1):
        try:
            resp = http.request(
                "GET",
                url,
                timeout=urllib3.Timeout(connect=5.0, read=25.0),
                headers={"Accept": "application/json"},
            )
            status = resp.status
            body = resp.data.decode("utf-8", errors="replace")

            if status == 200:
                return json.loads(body)

            # retryable status codes
            if status in (429, 500, 502, 503, 504) and attempt < max_attempts:
                backoff = min(max_backoff, 2 ** (attempt - 1))
                _sleep_jitter(backoff)
                continue

            raise RuntimeError(f"HTTP {status}: {body[:250]}")

        except Exception as e:
            last_err = e
            if attempt < max_attempts:
                backoff = min(max_backoff, 2 ** (attempt - 1))
                _sleep_jitter(backoff)
                continue

    raise RuntimeError(f"Request failed after retries: {last_err}")


def discover_last_trading_dates(
    http: urllib3.PoolManager,
    limiter: SmoothRateLimiter,
    base_url: str,
    api_key: str,
    end_date: str,
    n: int,
    max_attempts: int,
    max_backoff: float,
) -> list[str]:
    end = datetime.strptime(end_date, "%Y-%m-%d").date()
    start = end - timedelta(days=25)

    # Use AAPL as the “calendar source” for trading days.
    url = (
        f"{base_url}/v2/aggs/ticker/AAPL/range/1/day/{start}/{end}"
        f"?adjusted=true&apiKey={api_key}"
    )

    limiter.wait()
    data = _get_json(http, url, max_attempts=max_attempts, max_backoff=max_backoff)
    results = data.get("results") or []
    if not results:
        raise RuntimeError("No results returned while discovering trading dates. Check endpoint/API key.")

    dates = sorted(set(_date_str_from_epoch_ms(int(bar["t"])) for bar in results))
    dates = [d for d in dates if d <= end_date]

    if len(dates) < n:
        raise RuntimeError(f"Only found {len(dates)} trading dates <= {end_date}. Widen the window.")
    return dates[-n:]


def fetch_day(
    http: urllib3.PoolManager,
    limiter: SmoothRateLimiter,
    base_url: str,
    api_key: str,
    symbol: str,
    date_yyyy_mm_dd: str,
    max_attempts: int,
    max_backoff: float,
) -> tuple[float, float, str]:
    url = (
        f"{base_url}/v2/aggs/ticker/{symbol}/range/1/day/{date_yyyy_mm_dd}/{date_yyyy_mm_dd}"
        f"?adjusted=true&apiKey={api_key}"
    )
    limiter.wait()
    data = _get_json(http, url, max_attempts=max_attempts, max_backoff=max_backoff)

    results = data.get("results") or []
    if not results:
        raise RuntimeError(f"No results for {symbol} on {date_yyyy_mm_dd}")

    bar = results[0]
    o = float(bar["o"])
    c = float(bar["c"])
    actual_date = _date_str_from_epoch_ms(int(bar["t"]))
    return o, c, actual_date


def already_exists(table, date_str: str) -> bool:
    resp = table.get_item(Key={"pk": "MOVERS", "sk": date_str})
    return "Item" in resp


def put_winner(table, date_str: str, ticker: str, pct: float, close: float) -> None:
    item = {
        "pk": "MOVERS",
        "sk": date_str,
        "Date": date_str,
        "Ticker": ticker,
        "PercentChange": _to_ddb_number(pct, places=6),
        "ClosingPrice": _to_ddb_number(close, places=2),
    }
    table.put_item(
        Item=item,
        ConditionExpression="attribute_not_exists(pk) AND attribute_not_exists(sk)",
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--end-date", required=True, help="End date (YYYY-MM-DD), inclusive.")
    parser.add_argument("--days", type=int, default=7, help="How many trading days to backfill (default 7).")
    args = parser.parse_args()

    aws_region = os.environ.get("AWS_REGION", "us-west-2")
    table_name = _require_env("TABLE_NAME")
    base_url = os.environ.get("MASSIVE_BASE_URL", "https://api.massive.com").rstrip("/")

    request_spacing = float(os.environ.get("REQUEST_SPACING_SECONDS", "12.5"))
    max_attempts = int(os.environ.get("MAX_ATTEMPTS", "4"))
    max_backoff = float(os.environ.get("MAX_BACKOFF_SECONDS", "10"))

    api_key = _get_massive_api_key(aws_region)

    http = urllib3.PoolManager()
    limiter = SmoothRateLimiter(request_spacing)

    dynamodb = boto3.resource("dynamodb", region_name=aws_region)
    table = dynamodb.Table(table_name)

    dates = discover_last_trading_dates(
        http=http,
        limiter=limiter,
        base_url=base_url,
        api_key=api_key,
        end_date=args.end_date,
        n=args.days,
        max_attempts=max_attempts,
        max_backoff=max_backoff,
    )

    print("Target trading dates (oldest -> newest):")
    for d in dates:
        print(" ", d)

    for d in dates:
        if already_exists(table, d):
            print(f"[SKIP] {d} already exists")
            continue

        moves = []
        for sym in WATCHLIST:
            o, c, actual_date = fetch_day(
                http=http,
                limiter=limiter,
                base_url=base_url,
                api_key=api_key,
                symbol=sym,
                date_yyyy_mm_dd=d,
                max_attempts=max_attempts,
                max_backoff=max_backoff,
            )

            if actual_date != d:
                raise RuntimeError(f"Date mismatch: asked {d} got {actual_date} for {sym}")

            if o == 0:
                raise RuntimeError(f"Open price is 0 for {sym} on {d}; cannot compute percent change")

            pct = ((c - o) / o) * 100.0
            moves.append((sym, pct, c))

        winner = max(moves, key=lambda x: abs(x[1]))
        print(f"[WRITE] {d} winner={winner[0]} pct={winner[1]:.4f} close={winner[2]:.2f}")
        put_winner(table, d, winner[0], winner[1], winner[2])

    print("Backfill complete.")


if __name__ == "__main__":
    main()