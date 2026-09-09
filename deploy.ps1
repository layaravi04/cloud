<#
.SYNOPSIS
  Zip and deploy Lambda code, ensure OrdersTable is a global table, and
  write the live failover-router Function URL into frontend/script.js.

.EXAMPLE
  .\deploy.ps1
#>

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$EastRegion = "us-east-1"
$WestRegion = "us-west-2"
$TableName = "OrdersTable"
$EastFunction = "orders-service-east"
$WestFunction = "orders-service-west"
$RouterFunction = "failover-router"
$Runtime = "python3.12"
$BuildDir = Join-Path $Root ".build"
$RegionalRoleName = "orders-failover-regional-role"
$RouterRoleName = "orders-failover-router-role"

function Assert-AwsCli {
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        throw "AWS CLI is not installed or not on PATH. Install it, then run aws configure."
    }
    aws sts get-caller-identity --output json | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI is not authenticated. Run aws configure (or set AWS credentials) and retry."
    }
}

function Invoke-Aws {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$AwsArgs,
        [switch]$AllowFail
    )
    $output = & aws @AwsArgs 2>&1
    $code = $LASTEXITCODE
    if (-not $AllowFail -and $code -ne 0) {
        throw "aws $($AwsArgs -join ' ') failed:`n$output"
    }
    return @{ Code = $code; Output = ($output | Out-String).Trim() }
}

function Get-AccountId {
    return (aws sts get-caller-identity --query Account --output text).Trim()
}

function Ensure-IamRole {
    param(
        [string]$RoleName,
        [string]$PolicyJson
    )

    $trust = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
"@

    $trustPath = Join-Path $BuildDir "trust-$RoleName.json"
    $policyPath = Join-Path $BuildDir "policy-$RoleName.json"
    Set-Content -Path $trustPath -Value $trust -Encoding ascii
    Set-Content -Path $policyPath -Value $PolicyJson -Encoding ascii

    $getRole = Invoke-Aws -AwsArgs @("iam", "get-role", "--role-name", $RoleName) -AllowFail
    if ($getRole.Code -ne 0) {
        Write-Host "Creating IAM role $RoleName"
        Invoke-Aws -AwsArgs @(
            "iam", "create-role",
            "--role-name", $RoleName,
            "--assume-role-policy-document", "file://$trustPath"
        ) | Out-Null
        Start-Sleep -Seconds 10
    }

    Invoke-Aws -AwsArgs @(
        "iam", "put-role-policy",
        "--role-name", $RoleName,
        "--policy-name", "inline",
        "--policy-document", "file://$policyPath"
    ) | Out-Null

    return (aws iam get-role --role-name $RoleName --query "Role.Arn" --output text).Trim()
}

function New-LambdaZip {
    param(
        [string]$SourceFile,
        [string]$ZipPath
    )
    if (Test-Path $ZipPath) {
        Remove-Item $ZipPath -Force
    }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip,
            $SourceFile,
            "lambda_function.py",
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
    finally {
        $zip.Dispose()
    }
}

function Ensure-Lambda {
    param(
        [string]$FunctionName,
        [string]$Region,
        [string]$RoleArn,
        [string]$ZipPath,
        [int]$Timeout,
        [hashtable]$Environment
    )

    $envPairs = ($Environment.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ","
    $exists = Invoke-Aws -AwsArgs @(
        "lambda", "get-function",
        "--function-name", $FunctionName,
        "--region", $Region
    ) -AllowFail

    if ($exists.Code -ne 0) {
        Write-Host "Creating Lambda $FunctionName in $Region"
        Invoke-Aws -AwsArgs @(
            "lambda", "create-function",
            "--function-name", $FunctionName,
            "--runtime", $Runtime,
            "--role", $RoleArn,
            "--handler", "lambda_function.lambda_handler",
            "--timeout", "$Timeout",
            "--zip-file", "fileb://$ZipPath",
            "--environment", "Variables={$envPairs}",
            "--region", $Region
        ) | Out-Null
    }
    else {
        Write-Host "Updating Lambda code $FunctionName in $Region"
        Invoke-Aws -AwsArgs @(
            "lambda", "update-function-code",
            "--function-name", $FunctionName,
            "--zip-file", "fileb://$ZipPath",
            "--region", $Region
        ) | Out-Null
        aws lambda wait function-updated --function-name $FunctionName --region $Region | Out-Null
        Invoke-Aws -AwsArgs @(
            "lambda", "update-function-configuration",
            "--function-name", $FunctionName,
            "--role", $RoleArn,
            "--timeout", "$Timeout",
            "--environment", "Variables={$envPairs}",
            "--region", $Region
        ) | Out-Null
    }

    aws lambda wait function-updated --function-name $FunctionName --region $Region | Out-Null
}

function Ensure-OrdersTable {
    Write-Host "Ensuring DynamoDB table $TableName in $EastRegion"
    $describeEast = Invoke-Aws -AwsArgs @(
        "dynamodb", "describe-table",
        "--table-name", $TableName,
        "--region", $EastRegion
    ) -AllowFail

    if ($describeEast.Code -ne 0) {
        Invoke-Aws -AwsArgs @(
            "dynamodb", "create-table",
            "--table-name", $TableName,
            "--attribute-definitions", "AttributeName=orderId,AttributeType=S",
            "--key-schema", "AttributeName=orderId,KeyType=HASH",
            "--billing-mode", "PAY_PER_REQUEST",
            "--region", $EastRegion
        ) | Out-Null
    }

    Write-Host "Waiting for $TableName to become ACTIVE in $EastRegion"
    aws dynamodb wait table-exists --table-name $TableName --region $EastRegion | Out-Null

    $replicas = aws dynamodb describe-table --table-name $TableName --region $EastRegion --query "Table.Replicas[].RegionName" --output text
    $hasWest = $replicas -match $WestRegion

    if (-not $hasWest) {
        Write-Host "Adding $WestRegion replica to $TableName"
        $replicaJson = '[{"Create":{"RegionName":"us-west-2"}}]'
        Invoke-Aws -AwsArgs @(
            "dynamodb", "update-table",
            "--table-name", $TableName,
            "--replica-updates", $replicaJson,
            "--region", $EastRegion
        ) | Out-Null
    }

    Write-Host "Waiting for global table replica in $WestRegion"
    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        $status = aws dynamodb describe-table --table-name $TableName --region $EastRegion --query "Table.Replicas[?RegionName=='$WestRegion'].ReplicaStatus | [0]" --output text
        if ($status -eq "ACTIVE") {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 10
    }
    if (-not $ready) {
        Write-Warning "Replica in $WestRegion is not ACTIVE yet. Check the DynamoDB console and re-run deploy.ps1 if needed."
    }
    else {
        Write-Host "OrdersTable global table is ACTIVE in $EastRegion and $WestRegion"
    }
}

function Ensure-FunctionUrl {
    param([string]$FunctionName, [string]$Region)

    $existing = Invoke-Aws -AwsArgs @(
        "lambda", "get-function-url-config",
        "--function-name", $FunctionName,
        "--region", $Region
    ) -AllowFail

    # Do not set Function URL CORS here. The Lambda already returns CORS headers.
    # Setting both causes duplicate Access-Control-Allow-Origin browser errors.
    if ($existing.Code -ne 0) {
        Write-Host "Creating Function URL for $FunctionName"
        Invoke-Aws -AwsArgs @(
            "lambda", "create-function-url-config",
            "--function-name", $FunctionName,
            "--auth-type", "NONE",
            "--region", $Region
        ) | Out-Null
    }

    Invoke-Aws -AwsArgs @(
        "lambda", "add-permission",
        "--function-name", $FunctionName,
        "--statement-id", "FunctionURLAllowPublicAccess",
        "--action", "lambda:InvokeFunctionUrl",
        "--principal", "*",
        "--function-url-auth-type", "NONE",
        "--region", $Region
    ) -AllowFail | Out-Null

    return (aws lambda get-function-url-config --function-name $FunctionName --region $Region --query FunctionUrl --output text).Trim()
}

function Set-FrontendRouterUrl {
    param([string]$FunctionUrl)

    $scriptPath = Join-Path $Root "frontend\script.js"
    $content = Get-Content -Raw -Path $scriptPath
    $updated = [regex]::Replace(
        $content,
        'const ROUTER_URL = ".*?";',
        "const ROUTER_URL = `"$FunctionUrl`";"
    )
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($scriptPath, $updated, $utf8)
    Write-Host "Updated frontend/script.js with $FunctionUrl"
}

# --- main ---
Assert-AwsCli
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

$accountId = Get-AccountId
Write-Host "Using AWS account $accountId"

Ensure-OrdersTable

$regionalPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:${accountId}:*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem"
      ],
      "Resource": [
        "arn:aws:dynamodb:${EastRegion}:${accountId}:table/${TableName}",
        "arn:aws:dynamodb:${WestRegion}:${accountId}:table/${TableName}"
      ]
    }
  ]
}
"@

$routerPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:${accountId}:*"
    },
    {
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": [
        "arn:aws:lambda:${EastRegion}:${accountId}:function:${EastFunction}",
        "arn:aws:lambda:${WestRegion}:${accountId}:function:${WestFunction}"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "lambda:PutFunctionConcurrency",
        "lambda:DeleteFunctionConcurrency",
        "lambda:GetFunctionConcurrency"
      ],
      "Resource": "arn:aws:lambda:${EastRegion}:${accountId}:function:${EastFunction}"
    }
  ]
}
"@

$regionalRoleArn = Ensure-IamRole -RoleName $RegionalRoleName -PolicyJson $regionalPolicy
$routerRoleArn = Ensure-IamRole -RoleName $RouterRoleName -PolicyJson $routerPolicy

$eastZip = Join-Path $BuildDir "orders-service-east.zip"
$westZip = Join-Path $BuildDir "orders-service-west.zip"
$routerZip = Join-Path $BuildDir "failover-router.zip"

New-LambdaZip -SourceFile (Join-Path $Root "lambda\orders-service-east\lambda_function.py") -ZipPath $eastZip
New-LambdaZip -SourceFile (Join-Path $Root "lambda\orders-service-west\lambda_function.py") -ZipPath $westZip
New-LambdaZip -SourceFile (Join-Path $Root "lambda\failover-router\lambda_function.py") -ZipPath $routerZip

Ensure-Lambda -FunctionName $EastFunction -Region $EastRegion -RoleArn $regionalRoleArn -ZipPath $eastZip -Timeout 10 -Environment @{ TABLE_NAME = $TableName }
Ensure-Lambda -FunctionName $WestFunction -Region $WestRegion -RoleArn $regionalRoleArn -ZipPath $westZip -Timeout 10 -Environment @{ TABLE_NAME = $TableName }
Ensure-Lambda -FunctionName $RouterFunction -Region $EastRegion -RoleArn $routerRoleArn -ZipPath $routerZip -Timeout 30 -Environment @{ TABLE_NAME = $TableName }

# Same-account cross-region invoke is allowed by identity policy; add resource policy on West for clarity.
Invoke-Aws -AwsArgs @(
    "lambda", "add-permission",
    "--function-name", $WestFunction,
    "--statement-id", "AllowFailoverRouterInvoke",
    "--action", "lambda:InvokeFunction",
    "--principal", $routerRoleArn,
    "--region", $WestRegion
) -AllowFail | Out-Null

$functionUrl = Ensure-FunctionUrl -FunctionName $RouterFunction -Region $EastRegion
Set-FrontendRouterUrl -FunctionUrl $functionUrl

Write-Host ""
Write-Host "Deployment complete."
Write-Host "Router Function URL: $functionUrl"
Write-Host "Launch the dashboard with:"
Write-Host "  Start-Process `"$Root\frontend\index.html`""
Write-Host "Or run: python -m http.server 8080 --directory frontend"
Write-Host "Then open http://localhost:8080"
