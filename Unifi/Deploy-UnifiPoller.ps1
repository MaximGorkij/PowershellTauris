# Deploy-UnifiPoller.ps1
# Nasadí UniFi Poller stack do Portainera cez API

param(
    [string]$PortainerUrl    = "https://10.60.20.85:9443",
    [string]$ApiKey          = "glsa_3KWlXUPjehG4UpiOKqdJNyU7ggzaXhv5_731ad02e",
    [string]$StackName       = "unifi-poller",

    # UniFi Controller
    [string]$UnifiUrl        = "https://10.20.10.235",   # URL tvojho UniFi controllera
    [string]$UnifiUser       = "unifipoller",
    [string]$UnifiPass       = "Karabin@-2026",
    [switch]$UnifiVerifySsl  = $false,                  # false = self-signed cert

    # Prometheus port (expozícia metrík)
    [int]$PrometheusPort     = 9130
)

$headers = @{
    "X-API-Key"    = $ApiKey
    "Content-Type" = "application/json"
}

# ── 1. Zisti endpoint ID ────────────────────────────────────────────────────
Write-Host "Hľadám Portainer endpoint..." -ForegroundColor Yellow
$endpoints = Invoke-RestMethod -Uri "$PortainerUrl/api/endpoints" `
    -Method Get -Headers $headers -SkipCertificateCheck

$endpoint = $endpoints | Where-Object { $_.Name -eq 'local' -or $_.Type -eq 1 } | Select-Object -First 1
if (-not $endpoint) {
    Write-Host "Nenasiel sa local Docker endpoint." -ForegroundColor Red
    exit 1
}
Write-Host "Endpoint: $($endpoint.Name) (ID: $($endpoint.Id))" -ForegroundColor Green

# ── 2. Skontroluj, či stack už existuje ────────────────────────────────────
$stacks = Invoke-RestMethod -Uri "$PortainerUrl/api/stacks" `
    -Method Get -Headers $headers -SkipCertificateCheck

$existing = $stacks | Where-Object { $_.Name -eq $StackName }
if ($existing) {
    Write-Host "Stack '$StackName' už existuje (ID: $($existing.Id))." -ForegroundColor Yellow
    $answer = Read-Host "Chceš ho prepísať? (a/n)"
    if ($answer -ne 'a') {
        Write-Host "Zrušené." -ForegroundColor Gray
        exit 0
    }
    # Zmaž existujúci stack
    Invoke-RestMethod -Uri "$PortainerUrl/api/stacks/$($existing.Id)?endpointId=$($endpoint.Id)" `
        -Method Delete -Headers $headers -SkipCertificateCheck | Out-Null
    Write-Host "Starý stack odstránený." -ForegroundColor Gray
}

# ── 3. Docker Compose obsah ────────────────────────────────────────────────
$verifySsl = if ($UnifiVerifySsl) { "true" } else { "false" }

$composeContent = @"
services:
  unifi-poller:
    image: golift/unifi-poller:latest
    container_name: unifi-poller
    restart: unless-stopped
    ports:
      - "${PrometheusPort}:9130"
    environment:
      UP_UNIFI_DEFAULT_URL: "${UnifiUrl}"
      UP_UNIFI_DEFAULT_USER: "${UnifiUser}"
      UP_UNIFI_DEFAULT_PASS: "${UnifiPass}"
      UP_UNIFI_DEFAULT_VERIFY_SSL: "${verifySsl}"
      UP_INFLUXDB_DISABLE: "true"
      UP_PROMETHEUS_DISABLE: "false"
      UP_PROMETHEUS_HTTP_LISTEN: "0.0.0.0:9130"
      UP_LOKI_DISABLE: "true"
      UP_POLLER_DEBUG: "false"
"@

# ── 4. Nasaď stack ─────────────────────────────────────────────────────────
$body = @{
    name             = $StackName
    stackFileContent = $composeContent
    env              = @()
} | ConvertTo-Json -Depth 5

$uri = "$PortainerUrl/api/stacks/create/standalone/string?endpointId=$($endpoint.Id)"

Write-Host "Nasadzujem stack '$StackName'..." -ForegroundColor Yellow

try {
    $result = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
        -Body $body -SkipCertificateCheck

    Write-Host "Stack nasadený!" -ForegroundColor Green
    Write-Host "  ID:     $($result.Id)"
    Write-Host "  Meno:   $($result.Name)"
    Write-Host "  Status: $($result.Status)"
    Write-Host ""
    Write-Host "Prometheus metriky dostupné na: http://10.60.20.85:${PrometheusPort}/metrics" -ForegroundColor Cyan
}
catch {
    Write-Host "Chyba pri nasadzovaní stacku: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Response) {
        $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
        Write-Host $reader.ReadToEnd() -ForegroundColor Red
    }
    exit 1
}
