# Stocks Serverless Pipeline

Fully automated serverless pipeline on AWS that:
- determines which stock from a fixed tech watchlist moved the most each trading day (by absolute percentage change) 
- stores one winner record per day in DynamoDB
- serves the last 7 days through a REST API to a public S3-hosted frontend. 

For each trading day, persist:

- Date
- Ticker
- Percent Change
- Closing Price

Expose `GET /movers` returning the most recent 7 days and visualize on a public frontend.

All infrastructure is provisioned with Terraform — no AWS Console clicks required.

**Watchlist:** `AAPL` · `MSFT` · `GOOGL` · `AMZN` · `TSLA` · `NVDA`

**Formula:** `((Close − Open) / Open) × 100` — winner is the ticker with the largest absolute value.

**Live demo:**
- **Frontend:** http://stocks-serverless-pipeline-dev-frontend-876442842164.s3-website-us-west-2.amazonaws.com
- **API endpoint:** https://8kf3ke72bd.execute-api.us-west-2.amazonaws.com/dev/movers

---

## Table of Contents

- [Architecture (AWS-Only, Serverless)](#architecture-aws-only-serverless)
- [Tech Stack](#tech-stack)
- [Repo Structure](#repo-structure)
- [Design Choices](#design-choices)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Full Deploy Instructions](#full-deploy-instructions)
  - [Step A — Bootstrap Remote State](#step-a--bootstrap-remote-state)
  - [Step B — Configure & Deploy Main Infrastructure](#step-b--configure--deploy-main-infrastructure)
  - [Step C — Set Massive API Key & Apply](#step-c--set-massive-api-key--apply)
  - [Step D — Verify EventBridge Schedule & Trigger Ingestion](#step-d--verify-eventbridge-schedule--trigger-ingestion)
  - [Step E — Verify DynamoDB Record](#step-e--verify-dynamodb-record)
  - [Step F — Verify GET /movers API](#step-f--verify-get-movers-api)
  - [Step G — Verify Frontend](#step-g--verify-frontend)
- [Configuration Reference](#configuration-reference)
- [Data Model](#data-model)
- [API Contract](#api-contract)
- [Reliability & Rate-Limit Strategy](#reliability--rate-limit-strategy)
- [Security Notes](#security-notes)
- [Cost & Free-Tier Notes](#cost--free-tier-notes)
- [Known Tradeoffs & Non-Goals](#known-tradeoffs--non-goals)
- [Troubleshooting](#troubleshooting)
- [Teardown / Cleanup](#teardown--cleanup)
- [Appendix: Backfill Script (Optional)](#appendix-backfill-script-optional)

---

## Architecture (AWS-Only, Serverless)

### Infrastructure

- **Terraform** provisions all resources (no click-ops).
- **S3 backend + DynamoDB lock table** for Terraform remote state.

```
                                    ┌─────────────┐
                  daily cron        │   Massive   │
               ┌──────────────┐     │  Stock API  │
               │  EventBridge │     └──────▲──────┘
               │   Schedule   │            │  HTTP GET /ticker/{sym}/prev
               └──────┬───────┘            │
                      │ invoke    ┌────────┴───────────┐
                      └──────────▶│  Ingest Lambda     │
                                  │  (ingest_mover)    │
                                  │  Python 3.12       │
                                  └────────┬───────────┘
                                           │ PutItem (1 winner/day)
                                           ▼
                                  ┌──────────────────┐
                                  │    DynamoDB      │
                                  │  pk = "MOVERS"   │
                                  │  sk = YYYY-MM-DD │
                                  └────────▲─────────┘
                                           │ Query (limit 7, newest first)
                                  ┌────────┴──────────┐
               ┌──────────────┐   │  Retrieval Lambda │
               │ API Gateway  │──▶│  (get_movers)     │
               │ GET /movers  │◀──│  Python 3.12      │
               └──────▲───────┘   └───────────────────┘
                      │  fetch(/movers)
               ┌──────┴───────┐
               │  S3 Static   │
               │  Website     │
               │  (Frontend)  │
               └──────────────┘
                      ▲
                      │ browser
                 [ User ]
```

### Data Ingestion Path

1. EventBridge schedule triggers `ingest_mover` Lambda daily.
2. Lambda calls Massive market data API for each ticker in the watchlist.
3. Lambda computes `% change = ((close - open) / open) * 100`.
4. Lambda selects the single winner by largest absolute `% change`.
5. Lambda writes one item per day to DynamoDB (`pk=MOVERS`, `sk=YYYY-MM-DD`).

### Retrieval Path

1. API Gateway REST endpoint `GET /movers` invokes `get_movers` Lambda.
2. Lambda queries DynamoDB partition `MOVERS`, newest first, limit 7.
3. Returns JSON array with public fields only (`Date`, `Ticker`, `PercentChange`, `ClosingPrice`).

### Frontend Path

1. Static SPA is hosted on S3 website hosting.
2. Terraform uploads frontend files and generates `config.js` with the real API Gateway URL (the local `frontend/config.js` is a harmless `"REPLACE_ME"` placeholder).
3. Browser calls `GET /movers`, renders a sortable table, and color-codes gain (green) / loss (red).

---

## Tech Stack

| Service | Role | Why |
|---------|------|-----|
| **Terraform** | IaC | All infrastructure as code; remote state in S3 + DynamoDB locking |
| **AWS Lambda** (Python 3.12) | Compute | Two separate functions: ingestion + retrieval (separation of concerns) |
| **Amazon DynamoDB** | Storage | Serverless NoSQL; pay-per-request; one item per trading day |
| **Amazon EventBridge** | Scheduler | Daily cron trigger for ingestion Lambda |
| **Amazon API Gateway** (REST) | API layer | `GET /movers` with Lambda proxy integration + CORS |
| **Amazon S3** | Frontend hosting | Static website hosting for the SPA |
| **AWS SSM Parameter Store** | Secret storage | Massive API key stored as SecureString (KMS-encrypted) |
| **AWS KMS** | Encryption | Decrypts SSM SecureString at Lambda runtime |

---

## Repo Structure

```
.
├── infra-bootstrap/            # One-time Terraform: remote state S3 bucket + DynamoDB lock table
│   ├── main.tf
│   └── .terraform.lock.hcl
├── infra/                      # Main Terraform stack
│   ├── apigateway.tf           # REST API, GET /movers, CORS OPTIONS, deployment + stage
│   ├── backend.tf              # S3 remote state backend config
│   ├── dynamodb.tf             # Top movers table (pk/sk)
│   ├── eventbridge.tf          # Daily cron schedule → ingest Lambda
│   ├── frontend_s3.tf          # S3 bucket, website config, public policy, file uploads, config.js
│   ├── iam.tf                  # Two separate least-privilege IAM roles (ingest + retrieval)
│   ├── lambda_ingest.tf        # Ingest Lambda definition, env vars, zip packaging
│   ├── lambda_get_movers.tf    # Retrieval Lambda definition, env vars, zip packaging
│   ├── locals.tf               # name_prefix, common_tags
│   ├── main.tf                 # aws_caller_identity data source
│   ├── outputs.tf              # All key endpoints, resource names, and URLs
│   ├── providers.tf            # AWS provider config: region, allowed_account_ids, default_tags
│   ├── ssm.tf                  # SSM SecureString for Massive API key (seed-once pattern)
│   ├── variables.tf            # All configurable inputs with defaults + validations
│   ├── versions.tf             # Required Terraform + provider versions
│   └── .terraform.lock.hcl     # Pinned provider hashes (committed per best practice)
├── lambdas/
│   ├── ingest_mover/app.py     # Daily ingestion: fetch 6 tickers, compute winner, store
│   └── get_movers/app.py       # API retrieval: query DynamoDB, return last 7, CORS headers
├── frontend/
│   ├── index.html              # SPA markup (semantic HTML5, accessible table)
│   ├── app.js                  # Fetch, render, sort, color-code, highlight biggest mover
│   ├── styles.css              # Dark-theme responsive styles with gain/loss colors
│   └── config.js               # Local placeholder; Terraform generates the real one on S3
├── scripts/
│   ├── backfill_to_7_days.py   # Optional: seed DynamoDB with 7 recent trading days
│   ├── requirements.txt        # Python deps for backfill script (boto3, urllib3)
│   └── .gitignore
├── .gitignore                  # Excludes .terraform/, *.tfstate, *.tfvars, .env, keys, dist/, *.zip
└── README.md
```

**Not committed (gitignored):** `dist/` (auto-generated Lambda zips), `*.tfstate`, `.terraform/` caches, `*.tfvars`, `.env`, `**/key.json`.

---

## Design Choices

> Aligned with IaC quality, separation of concerns, error handling, and documentation.

### Separation of concerns

- **Ingestion Lambda** (`ingest_mover`) is fully separate from **Retrieval Lambda** (`get_movers`) — different code, different IAM roles, different Terraform files.
- Event-driven write path (EventBridge → Lambda → DynamoDB) and API read path (API Gateway → Lambda → DynamoDB) are independently deployable and scalable.

### Idempotency and correctness

- Ingestion fetches ONE ticker (AAPL) to discover the trading date, then checks DynamoDB. If a record already exists for that date, it returns immediately — the remaining 5 tickers are never called.
- DynamoDB `ConditionExpression` (`attribute_not_exists(pk) AND attribute_not_exists(sk)`) on PutItem prevents duplicate records even under concurrent invocations.
- Each subsequent ticker's response is validated to match the same trading date as the first; a mismatch raises an error.
- If **any** ticker fails after retries, ingestion aborts the entire run rather than writing a winner computed from partial data (all-or-nothing).

### Rate-limit resilience

- `SmoothRateLimiter` paces outbound API calls (default 12.5s spacing between each ticker request).
- Exponential backoff with jitter for HTTP 429, 5xx, and connection/timeout errors.
- All pacing and retry knobs are configurable via Terraform variables → Lambda environment variables.

### Security posture

- Massive API key is stored in **SSM Parameter Store SecureString** (KMS-encrypted).
- Lambda reads and decrypts the key at runtime via least-privilege IAM (`ssm:GetParameter` + `kms:Decrypt`, scoped to exact ARNs).
- Secrets, state files, and build artifacts are excluded from git via `.gitignore`.

### Reproducibility

- All infrastructure is codified in Terraform — no manual console setup.
- Remote state with S3 backend + DynamoDB locking prevents concurrent corruption.
- Deployment steps in this README are explicit, ordered, and deterministic.

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| **AWS CLI v2** | Configured with credentials — `aws sts get-caller-identity` must succeed |
| **Terraform ≥ 1.6** | [Install guide](https://developer.hashicorp.com/terraform/install) |
| **Python 3.12** | Only needed if you run the optional backfill script |
| **Massive API key** | Free tier at [massive.com](https://massive.com) — **do not commit this key** |

Your AWS credentials need permissions for: IAM, Lambda, DynamoDB, API Gateway, EventBridge, SSM, S3, KMS.

---

## Full Deploy Instructions

All steps include commands for both Bash (macOS/Linux/Git Bash) and PowerShell (Windows).
Use the section that matches your shell.

### Step A — Bootstrap Remote State

The bootstrap creates the S3 bucket and DynamoDB table that Terraform uses for its own state and locking. This runs once per AWS account.

✅ **No manual edits required:** `infra-bootstrap/main.tf` derives the state bucket name from your AWS account ID automatically (globally unique) and enables S3 versioning for safer state recovery.

```bash
cd infra-bootstrap
terraform init
terraform apply
```

**What to expect:**

```
Apply complete! Resources: ... added, 0 changed, 0 destroyed.

Outputs:
  lock_table_name   = "stocks-serverless-pipeline-terraform-locks"
  state_bucket_name = "stocks-serverless-pipeline-terraform-state-<YOUR_ACCOUNT_ID>"
```

Save both output values — you need them in the next step.

---

### Step B — Configure & Deploy Main Infrastructure

**B1. Update the backend config.**

Open `infra/backend.tf` and set `bucket` to match your bootstrap output:

```hcl
terraform {
  backend "s3" {
    bucket         = "stocks-serverless-pipeline-terraform-state-<YOUR_ACCOUNT_ID>"
    key            = "env/dev/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "stocks-serverless-pipeline-terraform-locks"
    encrypt        = true
  }
}
```

> Terraform backend blocks do not support variable interpolation — this manual edit is a one-time requirement.

**B2. Initialize.**

```bash
cd ../infra
terraform init
```

**What to expect:** `Terraform has been successfully initialized!`

---

### Step C — Set Massive API Key & Apply

The Massive API key is stored as an SSM SecureString. You only need to provide it on the **first** `terraform apply`. After SSM is seeded, Terraform reads the existing value automatically and you never need to supply the secret again.

**First, provide your API key using one of these methods:**

**Option A — Environment variable (recommended, ephemeral):**

- Bash (macOS / Linux / Git Bash):

```bash
export TF_VAR_massive_api_key="YOUR_MASSIVE_API_KEY"
```

- PowerShell (Windows):

```powershell
$env:TF_VAR_massive_api_key="YOUR_MASSIVE_API_KEY"
```

**Option B — Gitignored tfvars file:**

- Bash (macOS / Linux / Git Bash):

```bash
echo 'massive_api_key = "YOUR_MASSIVE_API_KEY"' > dev.tfvars
```

- PowerShell (Windows):

```powershell
'massive_api_key = "YOUR_MASSIVE_API_KEY"' | Out-File -Encoding ascii dev.tfvars
```

**Then validate and deploy:**

```bash
terraform validate                          # catches syntax/config errors
terraform apply                             # if you used Option A
terraform apply -var-file="dev.tfvars"      # if you used Option B instead
```

**What to expect:** `Apply complete! Resources: ~25 added, 0 changed, 0 destroyed.`

**Capture key outputs:**

```bash
terraform output
```

You should see outputs including (with your specific values):

```
account_id                 = "123456789012"
dynamodb_table_name        = "stocks-serverless-pipeline-dev-top-movers"
eventbridge_rule_name      = "stocks-serverless-pipeline-dev-daily-ingest"
frontend_bucket_name       = "stocks-serverless-pipeline-dev-frontend-123456789012"
frontend_website_url       = "http://stocks-serverless-pipeline-dev-frontend-123456789012.s3-website-us-west-2.amazonaws.com"
get_movers_function_name   = "stocks-serverless-pipeline-dev-get-movers"
ingest_mover_function_name = "stocks-serverless-pipeline-dev-ingest-mover"
movers_endpoint            = "https://<api-id>.execute-api.us-west-2.amazonaws.com/dev/movers"
```

> **On subsequent deploys** (code changes, config tweaks): simply run `terraform apply` without setting the API key variable. Terraform will not prompt for it.

---

### Step D — Verify EventBridge Schedule & Trigger Ingestion

**Check the EventBridge rule:**

- Bash (macOS / Linux / Git Bash):

```bash
aws events describe-rule \
  --name "$(terraform output -raw eventbridge_rule_name)" \
  --region us-west-2
```

- PowerShell (Windows):

```powershell
$ruleName = terraform output -raw eventbridge_rule_name
aws events describe-rule --name $ruleName --region us-west-2
```

Look for `"ScheduleExpression": "cron(30 0 * * ? *)"` — this runs daily at 00:30 UTC.

**Manually trigger ingestion** (don't wait for the cron):

- Bash (macOS / Linux / Git Bash):

```bash
function_name=$(terraform output -raw ingest_mover_function_name)

aws lambda invoke \
  --function-name "$function_name" \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  --region us-west-2 \
  ./ingest_out.json

cat ./ingest_out.json
```

- PowerShell (Windows):

```powershell
$functionName = terraform output -raw ingest_mover_function_name

aws lambda invoke `
  --function-name $functionName `
  --payload '{}' `
  --cli-binary-format raw-in-base64-out `
  --region us-west-2 `
  .\ingest_out.json

Get-Content .\ingest_out.json
```

**Expected response (first run, trading day):**

```json
{
  "statusCode": 200,
  "body": "{\"stored\":true,\"cached\":false,\"item\":{\"pk\":\"MOVERS\",\"sk\":\"2026-02-10\",\"Date\":\"2026-02-10\",\"Ticker\":\"TSLA\",\"PercentChange\":1.234567,\"ClosingPrice\":312.45},\"successCount\":6,\"failureCount\":0,\"failures\":[]}"
}
```

Key fields to check: `"stored": true`, `"successCount": 6`, `"failureCount": 0`.

> **Weekend / holiday note:** The Massive API's `/prev` endpoint returns the most recent **trading day's** data. If you invoke on a Saturday, the Date in the response will be the preceding Friday (or Thursday if Friday was a holiday). This is correct behavior — it is not a bug.

**Expected response (second run, same day — idempotent):**

```json
{
  "statusCode": 200,
  "body": "{\"stored\":false,\"cached\":true,\"message\":\"already_stored\",\"tradingDate\":\"2026-02-10\", ...}"
}
```

`"cached": true` means the record already existed — no duplicate was written.

---

### Step E — Verify DynamoDB Record

- Bash (macOS / Linux / Git Bash):

```bash
aws dynamodb query \
  --table-name "$(terraform output -raw dynamodb_table_name)" \
  --key-condition-expression "pk = :p" \
  --expression-attribute-values '{":p":{"S":"MOVERS"}}' \
  --no-scan-index-forward \
  --limit 7 \
  --region us-west-2
```

- PowerShell (Windows):

```powershell
$tableName = terraform output -raw dynamodb_table_name

$exprValues = @{
  ":p" = @{ "S" = "MOVERS" }
} | ConvertTo-Json -Compress

$exprFile = Join-Path $env:TEMP "expr_values.json"
$exprValues | Out-File -Encoding ascii $exprFile

aws dynamodb query `
  --table-name $tableName `
  --key-condition-expression "pk = :p" `
  --expression-attribute-values file://$exprFile `
  --no-scan-index-forward `
  --limit 7 `
  --region us-west-2
```

**Expected — Items array with shape:**

```json
{
  "pk":            {"S": "MOVERS"},
  "sk":            {"S": "2026-02-10"},
  "Date":          {"S": "2026-02-10"},
  "Ticker":        {"S": "TSLA"},
  "PercentChange": {"N": "1.234567"},
  "ClosingPrice":  {"N": "312.450000"}
}
```

Verify: `Date` is `YYYY-MM-DD`, `Ticker` is one of the watchlist, `PercentChange` and `ClosingPrice` are numbers.

---

### Step F — Verify GET /movers API

- Bash (macOS / Linux / Git Bash):

```bash
curl -s "$(terraform output -raw movers_endpoint)" | python3 -m json.tool
```

- PowerShell (Windows):

```powershell
$endpoint = terraform output -raw movers_endpoint
Invoke-RestMethod -Uri $endpoint | ConvertTo-Json -Depth 5
```

**Expected (HTTP 200, JSON array, newest first, up to 7 items):**

```json
[
  {
    "Date": "2026-02-10",
    "Ticker": "TSLA",
    "PercentChange": 1.234567,
    "ClosingPrice": 312.45
  }
]
```

Verify: only public fields (`Date`, `Ticker`, `PercentChange`, `ClosingPrice`) — no `pk`/`sk`.

**Verify CORS headers:**

- Bash (macOS / Linux / Git Bash):

```bash
curl -s -D - "$(terraform output -raw movers_endpoint)" -o /dev/null | grep -i access-control
```

- PowerShell (Windows):

```powershell
$endpoint = terraform output -raw movers_endpoint
$response = Invoke-WebRequest -Uri $endpoint -Method GET -UseBasicParsing

$response.Headers.GetEnumerator() |
  Where-Object { $_.Key -like '*Access-Control*' } |
  ForEach-Object { "$($_.Key): $($_.Value)" }
```

Look for: `Access-Control-Allow-Origin: *`

---

### Step G — Verify Frontend

Open the S3 website URL:

- Bash (macOS / Linux / Git Bash):

```bash
terraform output -raw frontend_website_url
```

- PowerShell (Windows):

```powershell
terraform output -raw frontend_website_url
```

**What to expect in the browser:**

- Dark-themed page loads with title "Top Mover — Last 7 Full Trading Days"
- Table displays the ingested record(s)
- **Green** text for positive % change, **red** for negative
- "Last refreshed" timestamp in both PT and ET
- Column headers are sortable (click to toggle asc/desc)
- Biggest move in the window is highlighted
- If no data yet: status reads "No data yet. (Ingestion may not have run for enough days.)"

> **Note:** The S3 website uses HTTP (not HTTPS). HTTPS would require CloudFront. The API itself uses HTTPS.

---

## Configuration Reference

All variables are defined in `infra/variables.tf` with sensible defaults. Override via `TF_VAR_<name>` environment variables or a gitignored `.tfvars` file.

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-west-2` | AWS deployment region |
| `project_name` | `stocks-serverless-pipeline` | Prefix for all resource names |
| `environment` | `dev` | `dev` or `prod` (validated) |
| `massive_base_url` | `https://api.massive.com` | Massive API base URL |
| `massive_api_key` | `null` (sensitive) | Required on **first deploy only**; seeds SSM SecureString |
| `ingest_schedule_expression` | `cron(30 0 * * ? *)` | EventBridge cron in **UTC** (see note below) |
| `request_spacing_seconds` | `12.5` | Seconds between Massive API calls per ticker |
| `max_attempts` | `4` | Max retry attempts per ticker |
| `base_backoff_seconds` | `2` | Base exponential backoff for HTTP 429 |
| `base_5xx_backoff_seconds` | `0.5` | Base exponential backoff for HTTP 5xx |
| `max_backoff_seconds` | `10` | Backoff cap for retries |
| `allowed_account_ids` | `[]` | Optional safety guard: restrict Terraform to specific AWS account(s) |

**Schedule note:** EventBridge cron uses UTC. The default `cron(30 0 * * ? *)` runs at **00:30 UTC daily**, which is approximately 4:30 PM PT / 7:30 PM ET (PST) or 5:30 PM PT / 8:30 PM ET (PDT). US markets close at 4:00 PM ET, so the Massive `/prev` endpoint has the completed trading day's data by this time.

---

## Data Model

**DynamoDB table:** `stocks-serverless-pipeline-dev-top-movers`

| Attribute | Type | Role |
|-----------|------|------|
| `pk` | String | Partition key — always `"MOVERS"` |
| `sk` | String | Sort key — trading date `YYYY-MM-DD` |
| `Date` | String | Trading date (same as `sk`) |
| `Ticker` | String | Winning ticker symbol |
| `PercentChange` | Number | `((Close − Open) / Open) × 100`, signed, 6 decimal places |
| `ClosingPrice` | Number | Closing price, 6 decimal places |

**Example item:**

```json
{
  "pk": "MOVERS",
  "sk": "2026-02-10",
  "Date": "2026-02-10",
  "Ticker": "NVDA",
  "PercentChange": -2.345678,
  "ClosingPrice": 875.123456
}
```

**Key design:** Single-partition model (`pk=MOVERS`) enables efficient newest-first queries via `ScanIndexForward=false` on the `sk` sort key. One item per trading day is enforced by a `ConditionExpression` on PutItem.

---

## API Contract

### `GET /movers`

**Request:**

```
GET https://<api-id>.execute-api.us-west-2.amazonaws.com/dev/movers
```

**Success response (200):**

```json
[
  {
    "Date": "2026-02-10",
    "Ticker": "NVDA",
    "PercentChange": -2.345678,
    "ClosingPrice": 875.123456
  },
  {
    "Date": "2026-02-07",
    "Ticker": "TSLA",
    "PercentChange": 4.123456,
    "ClosingPrice": 312.45
  }
]
```

- **Ordering:** Most recent first (newest `Date` at index 0)
- **Limit:** Up to 7 items
- **Fields:** Only `Date`, `Ticker`, `PercentChange`, `ClosingPrice` (internal fields `pk`/`sk` are stripped)

**Error response (500):**

```json
{"error": "Internal server error"}
```

Full details are logged to CloudWatch — never exposed to clients.

**CORS headers (on every response):**

```
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET,OPTIONS
Access-Control-Allow-Headers: Content-Type,Authorization,X-Amz-Date,X-Api-Key,X-Amz-Security-Token
```

An `OPTIONS /movers` preflight endpoint is also configured (MOCK integration) returning matching CORS headers with `Access-Control-Max-Age: 3600`.

---

## Reliability & Rate-Limit Strategy

### Request pacing

The ingestion Lambda spaces Massive API calls by `REQUEST_SPACING_SECONDS` (default 12.5s) using a `SmoothRateLimiter`. With 6 tickers, baseline execution time is ~75 seconds.

### Retry & backoff

| Scenario | Behavior |
|----------|----------|
| HTTP 429 (rate limited) | Exponential backoff from `BASE_429_BACKOFF_SECONDS` (2s), capped at `MAX_BACKOFF_SECONDS` (10s), with random jitter |
| HTTP 5xx (server error) | Exponential backoff from `BASE_5XX_BACKOFF_SECONDS` (0.5s), capped at 10s, with jitter |
| Connection / timeout error | Same as 5xx backoff |
| Max attempts exceeded | Raises exception; entire run is aborted |

All knobs are configurable via Terraform variables → Lambda environment variables.

### All-or-nothing semantics

If **any** ticker fails after all retries, the Lambda refuses to store a winner. This prevents writing a "winner" computed from partial data (e.g., only 4 of 6 tickers succeeded).

### Idempotency (one record per day guarantee)

1. **Early short-circuit:** Before fetching all 6 tickers, the Lambda makes ONE API call (for AAPL) to learn the trading date, then checks DynamoDB. If a record already exists for that date, it returns immediately — no additional API calls made.
2. **DynamoDB ConditionExpression:** `attribute_not_exists(pk) AND attribute_not_exists(sk)` on PutItem prevents duplicate writes even under concurrent invocations.
3. **Graceful race handling:** If a concurrent write wins the race, the Lambda catches `ConditionalCheckFailedException` and returns success (not an error).

### Lambda configurations

| Function | Runtime | Handler | Timeout | Memory |
|----------|---------|---------|---------|--------|
| `ingest_mover` | Python 3.12 | `app.handler` | 180s | 128 MB |
| `get_movers` | Python 3.12 | `app.handler` | 15s | 128 MB |

The ingest timeout (180s) provides headroom for 6 paced calls (~75s baseline) plus worst-case retries.

---

## Security Notes

### Secret management

- Massive API key is stored as an **SSM Parameter Store SecureString** (encrypted with the default `aws/ssm` KMS key).
- Lambda reads and decrypts the key at runtime via `ssm:GetParameter` with `WithDecryption=True`.
- The key is provided to Terraform **only once** (first deploy) to seed SSM. After that, `lifecycle { ignore_changes = [value] }` prevents Terraform from overwriting manually rotated secrets.
- The API key is **never** stored in Lambda environment variables, source code, or git.

### IAM least privilege

Two separate roles with minimal permissions:

| Role | Permissions |
|------|-------------|
| **Ingest Lambda** | `dynamodb:PutItem` + `dynamodb:GetItem` (scoped to table ARN), `ssm:GetParameter` (scoped to parameter ARN), `kms:Decrypt` (scoped to SSM KMS key ARN), CloudWatch Logs |
| **Retrieval Lambda** | `dynamodb:Query` (scoped to table ARN), CloudWatch Logs |

The retrieval Lambda has **no** access to SSM, KMS, or DynamoDB write operations.

### Git hygiene

The `.gitignore` excludes:

- `.terraform/` directories (provider binaries, local state)
- `*.tfstate` and `*.tfstate.*` (Terraform state files)
- `*.tfvars` / `*.tfvars.json` (often contain secrets)
- `.env` / `.env.*` files
- `*.pem`, `*.key`, `**/key.json`
- `dist/`, `*.zip` (build artifacts)

**Verified:** No secrets, state files, or sensitive artifacts are tracked in git.

---

## Cost & Free-Tier Notes

This architecture targets AWS Free Tier / near-zero cost:

| Service | Usage | Free Tier |
|---------|-------|-----------|
| Lambda | ~1 invocation/day (ingest) + light API calls | 1M requests + 400K GB-s/month |
| DynamoDB | ~1 write/day + a few reads | On-demand: 2.5M reads + 1M writes/month (first 12 months) |
| API Gateway | Minimal request volume | 1M calls/month (first 12 months) |
| EventBridge | 1 scheduled rule | Always free |
| S3 | < 1 MB static files | 5 GB storage (first 12 months) |
| SSM Parameter Store | 1 standard parameter | Free |


---

## Known Tradeoffs & Non-Goals

| Decision | Rationale |
|----------|-----------|
| **HTTP frontend (no HTTPS)** | S3 website hosting is HTTP-only. HTTPS requires CloudFront, which adds complexity beyond scope. The API itself is HTTPS. |
| **No CloudFront / WAF** | Not required for a demo; adds cost and configuration surface |
| **Single-partition DynamoDB** | Sufficient at ~365 items/year; no GSIs or sharding needed |
| **Backend state config requires manual edit** | Terraform backend blocks don’t support variable interpolation. Reviewers must paste the bootstrap bucket name into `infra/backend.tf` once. |
| **Only stores daily winner** | Stores one record per day (as required). Full per-symbol history would need a different schema. |
| **Massive API rate limits** | Mitigated with pacing + retries, but extreme multi-minute throttling could still cause Lambda timeout |
| **stdlib `urllib` in Lambda** | Avoids packaging external HTTP libraries; retry logic implemented manually |

---

## Troubleshooting

### 1. `BucketAlreadyExists` during bootstrap

**Cause:** The derived S3 state bucket name already exists globally (rare), or the bucket already exists in your AWS account from a previous run.

**Fix:**
1. Confirm which AWS account you’re using:

```bash
aws sts get-caller-identity --query Account --output text
```

2. If you previously ran this project’s bootstrap in the same AWS account, the bucket may already exist. In that case, terraform apply should succeed (Terraform will detect/refresh existing resources).

3. If the bucket exists but you did not create it with this project, or you hit a true global name collision, make the bucket name unique by changing the suffix in `infra-bootstrap/main.tf`, for example:

```hcl
bucket = "stocks-serverless-pipeline-terraform-state-${data.aws_caller_identity.current.account_id}-v2"
```

Then re-run:

```bash
cd infra-bootstrap
terraform init
terraform apply
```

4. After changing the bootstrap bucket name, update `infra/backend.tf` to match the new bucket name and re-run:

```bash
cd ../infra
terraform init
```

### 2. `terraform init` fails — "Failed to get existing workspaces"

**Cause:** `infra/backend.tf` doesn't match your bootstrap outputs.

**Fix:** Ensure `bucket` and `dynamodb_table` in `backend.tf` exactly match the values from `terraform output` in `infra-bootstrap/`.

### 3. `No valid credential sources found`

**Cause:** AWS CLI is not configured.

**Fix:** Run `aws configure` or set `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_REGION`.

### 4. SSM parameter missing / Lambda errors with "Missing env var MASSIVE_API_KEY_PARAM"

**Cause:** First deploy was run without providing the API key, so SSM was never seeded.

**Fix:** Re-run `terraform apply` with `TF_VAR_massive_api_key` set.

### 5. Ingestion Lambda returns 429 errors or times out

**Cause:** Massive API rate limiting.

**Fix:** Increase `request_spacing_seconds` (default 12.5s). The Massive free tier allows ~5 calls/minute. If using the backfill script alongside normal invocations, increase spacing to 15–20s to stay safely under limits.

### 6. Frontend shows "No data yet"

**Cause:** DynamoDB has no records — ingestion hasn't run yet.

**Fix:** Manually invoke the Lambda (Step D above) or run the backfill script (see Appendix below). The EventBridge cron runs at 00:30 UTC daily.

### 7. Frontend shows "Config error: API URL not set"

**Cause:** You opened the local `frontend/index.html` file instead of the S3-hosted version. The local `config.js` contains `"REPLACE_ME"` as a placeholder — Terraform generates the real config and uploads it to S3.

**Fix:** Open the URL from `terraform output -raw frontend_website_url`.

### 8. CORS errors in browser console

**Cause:** API Gateway OPTIONS preflight may not be deployed correctly.

**Fix:** Ensure `terraform apply` completed fully. If you made manual API Gateway changes, re-run `terraform apply` to trigger a fresh deployment (the deployment resource uses content-based triggers).

### 9. `ConditionalCheckFailedException` in Lambda logs

**This is expected and safe.** It means a record for that trading date already exists. The Lambda handles this gracefully — idempotency is working correctly.

### 10. `terraform apply` prompts for `massive_api_key`

**Cause:** The SSM parameter doesn't exist yet and the variable wasn't provided.

**Fix:** This only happens on the first deploy. Set `TF_VAR_massive_api_key` and re-run. On all subsequent runs, Terraform reads the existing SSM value automatically.

---

## Teardown / Cleanup

Destroy in reverse order — main stack first, then bootstrap:

```bash
# 1. Destroy main infrastructure
cd infra
terraform destroy

# 2. Destroy bootstrap resources (state bucket + lock table)
cd ../infra-bootstrap
terraform destroy
```

> **Important:** Destroy the main stack **before** the bootstrap. The main stack's state is stored in the bootstrap's S3 bucket — if you destroy the bucket first, Terraform loses access to its own state file.

If you used a `.tfvars` file for the main stack:

```bash
terraform destroy -var-file="dev.tfvars"
```

---

## Appendix: Backfill Script (Optional)

`scripts/backfill_to_7_days.py` populates DynamoDB with the last 7 trading days of winner data. This lets the frontend show a full table immediately — without waiting 7 calendar days for the daily cron.

> This is optional. The main pipeline works without it.

**Install dependencies:**

- Bash (macOS / Linux / Git Bash):

```bash
cd scripts
pip install -r requirements.txt
```

- PowerShell (Windows):

```powershell
cd scripts
pip install -r requirements.txt
```

**Set environment variables:**

- Bash (macOS / Linux / Git Bash):

```bash
export AWS_REGION=us-west-2
export TABLE_NAME="$(cd ../infra && terraform output -raw dynamodb_table_name)"

# Option A (recommended): read API key from SSM
export MASSIVE_API_KEY_PARAM="/stocks-serverless-pipeline-dev/massive_api_key"

# Option B (fallback): provide key directly
export MASSIVE_API_KEY="YOUR_MASSIVE_API_KEY"
```

- PowerShell (Windows):

```powershell
$env:AWS_REGION = "us-west-2"

# Read Terraform output from the infra/ folder
$env:TABLE_NAME = (Push-Location ..\infra; terraform output -raw dynamodb_table_name; Pop-Location)

# Option A (recommended): read API key from SSM (SecureString)
$env:MASSIVE_API_KEY_PARAM = "/stocks-serverless-pipeline-dev/massive_api_key"

# Option B (fallback): provide key directly (do not commit)
$env:MASSIVE_API_KEY = "YOUR_MASSIVE_API_KEY"
```

**Run:**

- Bash (macOS / Linux / Git Bash):

```bash
python3 backfill_to_7_days.py --end-date YYYY-MM-DD --days 7
```

- PowerShell (Windows):

```powershell
python backfill_to_7_days.py --end-date YYYY-MM-DD --days 7
```

Replace `--end-date` with the most recent weekday (trading day).

**Behavior:**

- Discovers actual trading days (via AAPL calendar) within a 25-day lookback window
- Skips dates that already have a DynamoDB record (idempotent)
- Uses the same all-or-nothing logic and `ConditionExpression` as the Lambda
- Paces API calls at `REQUEST_SPACING_SECONDS` (default 12.5s)
- Total runtime: ~10 minutes for 7 days × 6 tickers

**Optional tuning variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `MASSIVE_BASE_URL` | `https://api.massive.com` | API base URL |
| `REQUEST_SPACING_SECONDS` | `12.5` | Delay between API calls |
| `MAX_ATTEMPTS` | `4` | Retries per call |
| `MAX_BACKOFF_SECONDS` | `10` | Backoff cap |

