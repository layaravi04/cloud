# Adaptive Multi-Region Failover (Orders)

College project that routes order traffic through a `failover-router` Lambda. **us-east-1** is primary. **us-west-2** is secondary. Both regional Lambdas share a DynamoDB global table named `OrdersTable`.

This architecture is **inspired by** [AWS Guidance for Resilient Data Applications Using Amazon DynamoDB](https://aws.amazon.com/solutions/guidance/resilient-data-applications-using-amazon-dynamodb/). This repository is **not** the official AWS implementation. It does not use Route 53, Application Recovery Controller, CloudWatch Synthetics, or FIS.

## Project objective

Show a simple, testable failover path:

1. A frontend calls a Lambda Function URL on `failover-router`.
2. The router health-checks `orders-service-east`.
3. If East is healthy, it forwards the request there.
4. If East fails, it health-checks `orders-service-west` and forwards there.
5. If both fail, the client receives HTTP 503.
6. Every successful routed response includes `served_by_region`.

## Architecture

```
User
  ↓
Frontend dashboard
  ↓
failover-router  (Lambda Function URL)
  ↓
orders-service-east (us-east-1)   ← primary
  or, if East is unhealthy
orders-service-west (us-west-2)   ← secondary
  ↓
DynamoDB global table: OrdersTable
```

See `architecture/architecture.png`.

## Run the demo (deploy + dashboard)

Prerequisites on your Windows machine:

- AWS CLI v2
- An IAM identity that can manage Lambda, IAM, and DynamoDB
- `aws configure` completed (or env vars `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`)

### 1. Deploy

From the repository root in PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\deploy.ps1
```

The script will:

1. Create or wait for DynamoDB `OrdersTable` in `us-east-1` (partition key `orderId`)
2. Add a `us-west-2` replica so it is a global table
3. Zip and deploy:
   - `orders-service-east` → `us-east-1`
   - `orders-service-west` → `us-west-2`
   - `failover-router` → `us-east-1`
4. Create/update a public Lambda Function URL on `failover-router` (CORS enabled)
5. Write that live URL into `frontend/script.js` as `ROUTER_URL`

If `orders-service-east` or `orders-service-west` already exist, the script **updates their code** instead of deleting them.

### 2. Launch the dashboard

After deploy finishes, either open the file:

```powershell
Start-Process .\frontend\index.html
```

Or serve it locally (better for CORS in some browsers):

```powershell
python -m http.server 8080 --directory frontend
```

Then open [http://localhost:8080](http://localhost:8080).

You should see **Currently Serving: us-east-1** and **System Status: HEALTHY**.

### 3. Demonstrate failover

On the dashboard, turn on **Simulate us-east-1 failure**. That sets East reserved concurrency to 0. After a few seconds, **Currently Serving** should become `us-west-2` and status **FAILOVER ACTIVE**.

Turn the switch off to restore East. Status should return to **HEALTHY** / `us-east-1`.

You can also create/read an order from the same page. Both regions use `OrdersTable`.

## AWS services used

`deploy.ps1` provisions the pieces below. You can still inspect them in the AWS Console.

- AWS Lambda (`orders-service-east`, `orders-service-west`, `failover-router`)
- Lambda Function URL on `failover-router`
- Amazon DynamoDB global table `OrdersTable`
- IAM roles/policies (`orders-failover-regional-role`, `orders-failover-router-role`)
- Amazon CloudWatch Logs (from `print` statements)
- Optional: API Gateway already in front of the regional Lambdas (kept compatible)

## Health checking

The router invokes East, then West if needed, with:

```json
{
  "httpMethod": "GET",
  "path": "/health"
}
```

Expected health body:

- East: `{ "status": "healthy", "region": "us-east-1" }`
- West: `{ "status": "healthy", "region": "us-west-2" }`

East invoke exceptions are caught so a dead primary does not crash the router.

## Regional APIs

Both regional Lambdas read `TABLE_NAME` from the environment (set it to `OrdersTable`). They do not hardcode credentials.

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | Health check |
| POST | `/orders` | Create order (`orderId` required) |
| GET | `/orders/{orderId}` | Retrieve order |

Example create body:

```json
{
  "orderId": "order-001",
  "customerId": "cust-001",
  "productId": "prod-001",
  "quantity": 1
}
```

## Failure simulation

The dashboard chaos switch calls `failover-router` (`POST /chaos/fail-east` and `POST /chaos/recover-east`). The router sets **reserved concurrency = 0** on `orders-service-east`. There is no separate chaos Lambda.

### Normal

East is enabled (unreserved concurrency).

Expected:

```json
"served_by_region": "us-east-1"
```

System status on the dashboard: **HEALTHY**.

### Failover

Turn on **Simulate us-east-1 failure** (or set reserved concurrency to 0 in the Console).

Expected:

```json
"served_by_region": "us-west-2"
```

System status: **FAILOVER ACTIVE**.

### Recovery

Turn the switch off (or restore unreserved concurrency on East).

Expected:

```json
"served_by_region": "us-east-1"
```

## Testing procedure

1. Run `.\deploy.ps1` (this creates the global table, deploys Lambdas, and fills `ROUTER_URL`).
2. Open `frontend/index.html` or `http://localhost:8080`.
3. Confirm **Currently Serving** is `us-east-1`.
4. Optionally create and read an order from the dashboard.
5. Toggle **Simulate us-east-1 failure**, wait a few seconds, confirm West.
6. Toggle it off, confirm East again.

## Expected responses

Normal health (through the router):

```json
{
  "status": "healthy",
  "region": "us-east-1",
  "served_by_region": "us-east-1"
}
```

Failover health:

```json
{
  "status": "healthy",
  "region": "us-west-2",
  "served_by_region": "us-west-2"
}
```

Both regions down:

HTTP **503**

```json
{
  "error": "Both regions unavailable",
  "served_by_region": null
}
```

Do not put AWS keys in this repository or in frontend code. `deploy.ps1` uses your local AWS CLI credentials only.

## IAM permissions

Do not store credentials in the repo. Use Lambda execution roles.

### failover-router

Needs `lambda:InvokeFunction` on:

- `orders-service-east` in `us-east-1`
- `orders-service-west` in `us-west-2`

For the dashboard chaos switch it also needs:

- `lambda:PutFunctionConcurrency`
- `lambda:DeleteFunctionConcurrency`
- `lambda:GetFunctionConcurrency`

on `orders-service-east` only. `deploy.ps1` attaches these on `orders-failover-router-role`.

Example policy shape:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": [
        "arn:aws:lambda:us-east-1:ACCOUNT_ID:function:orders-service-east",
        "arn:aws:lambda:us-west-2:ACCOUNT_ID:function:orders-service-west"
      ]
    }
  ]
}
```

If the router role is in a different account/region than West, also allow the West function resource policy to be invoked by that role.

### orders-service-east and orders-service-west

Need DynamoDB access to `OrdersTable` in their region, typically:

- `dynamodb:GetItem`
- `dynamodb:PutItem`

Optional if you expand later: `UpdateItem`, `Query`, `Scan`.

CloudWatch Logs permissions (`logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`) should stay on all three roles.

## Project structure

```
lambda/
  orders-service-east/lambda_function.py
  orders-service-west/lambda_function.py
  failover-router/lambda_function.py
frontend/
  index.html
  style.css
  script.js
architecture/
  architecture.png
README.md
.gitignore
deploy.ps1
```

## Deploying code

Prefer `.\deploy.ps1`. To update Lambdas later, run the same script again. It zips the Python files, updates function code, refreshes IAM, and rewrites `ROUTER_URL` in `frontend/script.js`.
