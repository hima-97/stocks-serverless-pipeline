# Stocks Serverless Pipeline (Pennymac TRE Take-Home)

Serverless AWS pipeline that:
- Runs daily to compute the top-moving stock from a watchlist
- Stores one record per day in DynamoDB
- Exposes GET /movers to return the last 7 days
- Hosts a simple frontend to display results

## Watchlist
AAPL, MSFT, GOOGL, AMZN, TSLA, NVDA

## Tech (planned)
- Terraform (Infrastructure as Code)
- AWS Lambda (Python)
- DynamoDB
- API Gateway (REST)
- EventBridge (daily schedule)
- S3 static website hosting (frontend)
