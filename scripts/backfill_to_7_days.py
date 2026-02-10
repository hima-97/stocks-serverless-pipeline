# This file is a standalone script to backfill the DynamoDB table with the last 7 full trading days of data, 
# as of a specified end date. It can be run from the command line and is idempotent (safe to re-run without creating duplicates).

import os
import json
import time
import random
from decimal import Decimal
from datetime import datetime, timezone, timedelta

import boto3
import urllib3

WATCHLIST = ["AAPL", "MSFT", "GOOGL", "AMZN", "TSLA", "NVDA"]

BASE_URL = os.environ.get("MASSIVE_BASE_URL", "https://api.massive.com")
API_KEY = os.environ["MASSIVE_API_KEY"]
TABLE_NAME = os.environ["TABLE_NAME"]
AWS_REGION = os.environ.get("AWS_REGION", "us-west-2")

REQUEST_SPACING_SECONDS = float(os.environ.get("REQUEST_SPACING_SECONDS", "12.5"))
MAX_ATTEMPTS = int(os.environ.get("MAX_ATTEMPTS", "4"))
MAX_BACKOFF_SECONDS = float(os.environ.get("MAX_BACKOFF_SECONDS", "10"))

http = urllib3.PoolManager()
dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table = dynamodb.Table(TABLE_NAME)


def _sleep_jitter(seconds: float) -> None:
    time.sleep(seconds + random.random() * 0.25)


class SmoothRateLimiter:
    def __init__(self, spacing_seconds: float):
        self.spacing = spacing_seconds
        self.next_ok = 0.0

    def wait(self):
        now = time.time()
        if now < self.next_ok:
            _sleep_jitter(self.next_ok - now)
        self.next_ok = time.time() + self.spacing


limiter = SmoothRateLimiter(REQUEST_SPACING_SECONDS)


def _get_json(url: str) -> dict:
    last_err = None
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            resp = http.request(
                "GET",
                url,
                timeout=urllib3.Timeout(connect=5.0, read=25.0),
            )
            status = resp.status
            body = resp.data.decode("utf-8", errors="replace")

            if status == 200:
                return json.loads(body)

            if status in (429, 500, 502, 503, 504):
                backoff = min(MAX_BACKOFF_SECONDS, 2 ** (attempt - 1))
                _sleep_jitter(backoff)
                continue

            raise RuntimeError(f"HTTP {status}: {body[:200]}")
        except Exception as e:
            last_err = e
            if attempt == MAX_ATTEMPTS:
                break
            backoff = min(MAX_BACKOFF_SECONDS, 2 ** (attempt - 1))
            _sleep_jitter(backoff)

    raise RuntimeError(f"Request failed after retries: {last_err}")


def _date_str_from_epoch_ms(ms: int) -> str:
    dt = datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc)
    return dt.strftime("%Y-%m-%d")


def discover_last_trading_dates(end_date: str, n: int = 7) -> list[str]:
    end = datetime.strptime(end_date, "%Y-%m-%d").date()
    start = end - timedelta(days=25)

    url = (
        f"{BASE_URL}/v2/aggs/ticker/AAPL/range/1/day/{start}/{end}"
        f"?adjusted=true&apiKey={API_KEY}"
    )
    limiter.wait()
    data = _get_json(url)

    results = data.get("results") or []
    if not results:
        raise RuntimeError("No results returned while discovering trading dates. Check endpoint and API key.")

    dates = sorted(set(_date_str_from_epoch_ms(int(bar["t"])) for bar in results))
    dates = [d for d in dates if d <= end_date]

    if len(dates) < n:
        raise RuntimeError(f"Only found {len(dates)} trading dates <= {end_date}. Widen the window.")
    return dates[-n:]


def fetch_day(symbol: str, date_yyyy_mm_dd: str) -> tuple[float, float, str]:
    url = (
        f"{BASE_URL}/v2/aggs/ticker/{symbol}/range/1/day/{date_yyyy_mm_dd}/{date_yyyy_mm_dd}"
        f"?adjusted=true&apiKey={API_KEY}"
    )
    limiter.wait()
    data = _get_json(url)

    results = data.get("results") or []
    if not results:
        raise RuntimeError(f"No results for {symbol} on {date_yyyy_mm_dd}")

    bar = results[0]
    o = float(bar["o"])
    c = float(bar["c"])
    actual_date = _date_str_from_epoch_ms(int(bar["t"]))
    return o, c, actual_date


def already_exists(date_str: str) -> bool:
    resp = table.get_item(Key={"pk": "MOVERS", "sk": date_str})
    return "Item" in resp


def put_winner(date_str: str, ticker: str, pct: float, close: float) -> None:
    item = {
        "pk": "MOVERS",
        "sk": date_str,
        "Date": date_str,
        "Ticker": ticker,
        "PercentChange": Decimal(str(round(pct, 6))),
        "ClosingPrice": Decimal(str(round(close, 2))),
    }
    table.put_item(
        Item=item,
        ConditionExpression="attribute_not_exists(pk) AND attribute_not_exists(sk)",
    )


def main():
    end_date = "2026-02-06"

    dates = discover_last_trading_dates(end_date=end_date, n=7)
    print("Target 7 trading dates (oldest -> newest):")
    for d in dates:
        print(" ", d)

    for d in dates:
        if already_exists(d):
            print(f"[SKIP] {d} already exists")
            continue

        moves = []
        for sym in WATCHLIST:
            o, c, actual_date = fetch_day(sym, d)
            if actual_date != d:
                raise RuntimeError(f"Date mismatch: asked {d} got {actual_date} for {sym}")

            pct = ((c - o) / o) * 100.0
            moves.append((sym, pct, c))

        winner = max(moves, key=lambda x: abs(x[1]))
        print(f"[WRITE] {d} winner={winner[0]} pct={winner[1]:.4f} close={winner[2]:.2f}")
        put_winner(d, winner[0], winner[1], winner[2])

    print("Backfill complete.")


if __name__ == "__main__":
    main()
