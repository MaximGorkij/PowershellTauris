# Get-PortainerStacks.ps1
# Lists all Docker Compose stacks in Portainer

param(
    [string]$PortainerUrl = "https://10.60.20.85:9443",
    [string]$ApiKey = "glsa_3KWlXUPjehG4UpiOKqdJNyU7ggzaXhv5_731ad02e"
)

$headers = @{
    "X-API-Key"    = $ApiKey
    "Content-Type" = "application/json"
}

# First, get the local Docker endpoint
$endpointsUri = "$PortainerUrl/api/endpoints"

try {
    Write-Host "Fetching endpoints..." -ForegroundColor Yellow
    $endpoints = Invoke-RestMethod -Uri $endpointsUri -Method Get -Headers $headers -SkipCertificateCheck

    Write-Host "Endpoints retrieved successfully." -ForegroundColor Green
    $endpoints | ForEach-Object { Write-Host "Endpoint: $($_.Name) (ID: $($_.Id), Type: $($_.Type))" }

    # Find the local Docker endpoint (usually the first one or named 'local')
    $localEndpoint = $endpoints | Where-Object { $_.Name -eq 'local' -or $_.Type -eq 1 } | Select-Object -First 1

    if (-not $localEndpoint) {
        Write-Host "Could not find local Docker endpoint." -ForegroundColor Red
        exit 1
    }

    Write-Host "Using endpoint: $($localEndpoint.Name) (ID: $($localEndpoint.Id))" -ForegroundColor Green

    $uri = "$PortainerUrl/api/endpoints/$($localEndpoint.Id)/stacks"

    Write-Host "Fetching stacks from $uri..." -ForegroundColor Yellow
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -SkipCertificateCheck

    if ($response -and $response.Count -gt 0) {
        Write-Host "Found $($response.Count) stacks:" -ForegroundColor Green
        Write-Host ("-" * 50)

        foreach ($stack in $response) {
            Write-Host "Name: $($stack.Name)" -ForegroundColor Cyan
            Write-Host "ID: $($stack.Id)"
            Write-Host "Status: $($stack.Status)"
            Write-Host "Created: $($stack.CreationDate)"
            Write-Host "Type: $($stack.Type)"
            Write-Host ("-" * 30)
        }
    }
    else {
        Write-Host "No stacks found." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Error retrieving stacks: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Response) {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Host "HTTP Status Code: $statusCode" -ForegroundColor Red
    }
}