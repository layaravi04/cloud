# Adaptive Multi-Region Failover (Orders)

A college project demonstrating **multi-region application failover using AWS Lambda and Amazon DynamoDB Global Tables**.

The system uses **us-east-1 as the primary region** and **us-west-2 as the secondary region**. A central `failover-router` Lambda checks the health of the primary service and automatically routes requests to the secondary region if the primary becomes unavailable.

## Project Objective

The project demonstrates:

* Multi-region deployment
* Health-aware request routing
* Automatic failover
* DynamoDB Global Tables for replicated data
* Lambda-based serverless architecture
* Basic order creation and retrieval
* A dashboard showing the currently serving region

## Architecture

```text
User
  ↓
Frontend Dashboard
  ↓
failover-router
Lambda Function URL
  ↓
 ┌─────────────────────────┐
 │                         │
 ▼                         ▼
orders-service-east   orders-service-west
   us-east-1             us-west-2
   Primary               Secondary
 │                         │
 └───────────┬─────────────┘
             ↓
      DynamoDB Global Table
          OrdersTable
```

## AWS Services Used

* **AWS Lambda** – application and routing logic
* **Lambda Function URL** – exposes the failover router
* **Amazon DynamoDB Global Tables** – replicates order data across regions
* **AWS IAM** – controls access between Lambda and DynamoDB
* **Amazon CloudWatch Logs** – monitors Lambda execution
* **Amazon S3** – optional hosting for the frontend dashboard

## Lambda Functions

### orders-service-east

* Region: `us-east-1`
* Role: Primary order service
* Handles health checks and order operations

### orders-service-west

* Region: `us-west-2`
* Role: Secondary/failover order service
* Handles requests when the primary region is unavailable

### failover-router

* Region: `us-east-1`
* Receives requests from the frontend
* Checks the health of `orders-service-east`
* Routes to East when healthy
* Routes to West when East is unavailable
* Returns HTTP `503` if both regions are unavailable

## Health Checking

The router checks the regional services using:

```json
{
  "httpMethod": "GET",
  "path": "/health"
}
```

Healthy responses identify their region:

```json
{
  "status": "healthy",
  "region": "us-east-1"
}
```

or:

```json
{
  "status": "healthy",
  "region": "us-west-2"
}
```

Every successful routed response also contains:

```json
"served_by_region": "us-east-1"
```

or:

```json
"served_by_region": "us-west-2"
```

## Order APIs

Both regional services use the `OrdersTable` DynamoDB Global Table.

| Method | Path                | Purpose              |
| ------ | ------------------- | -------------------- |
| GET    | `/health`           | Check service health |
| POST   | `/orders`           | Create an order      |
| GET    | `/orders/{orderId}` | Retrieve an order    |

Example order:

```json
{
  "orderId": "order-001",
  "customerId": "cust-001",
  "productId": "prod-001",
  "quantity": 1
}
```

## Failover Demonstration

### Normal Operation

The primary region is available.

```text
Currently Serving: us-east-1
System Status: HEALTHY
```

Expected response:

```json
{
  "served_by_region": "us-east-1"
}
```

### Primary Region Failure

The East Lambda is made unavailable for testing.

The router detects the failure and redirects requests to West.

```text
Currently Serving: us-west-2
System Status: FAILOVER ACTIVE
```

Expected response:

```json
{
  "served_by_region": "us-west-2"
}
```

### Recovery

When the East service becomes available again, the router automatically starts serving requests from:

```text
us-east-1
```

## Testing

1. Deploy the three Lambda functions.
2. Verify `OrdersTable` is active in both regions.
3. Open the frontend dashboard.
4. Confirm requests are served by `us-east-1`.
5. Create and retrieve an order.
6. Simulate failure of the East service.
7. Confirm traffic moves to `us-west-2`.
8. Restore the East service.
9. Confirm traffic returns to `us-east-1`.

## Project Structure

```text
lambda/
├── orders-service-east/
│   └── lambda_function.py
├── orders-service-west/
│   └── lambda_function.py
└── failover-router/
    └── lambda_function.py

frontend/
├── index.html
├── style.css
└── script.js

architecture/
└── architecture.png

README.md
.gitignore
deploy.ps1
```

## Security

* AWS credentials are **not stored in the repository**.
* Lambda uses IAM execution roles to access DynamoDB and other AWS services.
* No AWS access keys are included in frontend code.

## Key Technical Concepts

**Multi-Region Architecture:** Application components are deployed across multiple AWS regions to improve availability.

**Failover:** Automatically redirecting requests to a secondary region when the primary region becomes unavailable.

**DynamoDB Global Tables:** Provides multi-region, multi-active replication of DynamoDB data.

**Health Check:** A request used by the router to determine whether a regional service is available.

**Serverless Architecture:** Uses AWS Lambda without managing physical or virtual servers.

**Lambda Function URL:** Provides an HTTPS endpoint for directly invoking a Lambda function.

**IAM:** AWS service used to securely control permissions between resources.
