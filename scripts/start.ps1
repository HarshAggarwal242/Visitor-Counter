#Requires -Version 5.1
<#
.SYNOPSIS
    Start the Visitor Counter locally (Docker Compose) or on Kubernetes.

.DESCRIPTION
    -Mode docker : builds and starts Flask + Redis with Docker Compose, then
                   checks http://localhost:8080.
    -Mode k8s    : applies k8s.yaml + hpa.yaml to a Minikube cluster, waits for
                   the rollout and opens a tunnel on http://localhost:8080.
    -Mode all    : does both (Compose first, then Kubernetes).

.EXAMPLE
    .\scripts\start.ps1

.EXAMPLE
    .\scripts\start.ps1 -Mode k8s -Profile vc-primary
#>
[CmdletBinding()]
param(
    [ValidateSet('docker', 'k8s', 'all')]
    [string]$Mode = 'docker',

    [string]$Profile = 'vc-primary'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    [OK]   $Message" -ForegroundColor Green }
function Write-WarnMsg { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }

function Test-Endpoint {
    param([string]$Url, [int]$Attempts = 20, [int]$DelaySeconds = 3)
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -eq 200) { return $true }
        } catch {
            # not ready yet
        }
        Start-Sleep -Seconds $DelaySeconds
        Write-Info "waiting for $Url ($i/$Attempts)"
    }
    return $false
}

function Start-Docker {
    Write-Step 'Starting the Docker Compose stack'
    & docker compose up -d --build
    if ($LASTEXITCODE -ne 0) { throw 'docker compose up failed.' }

    Write-Step 'Waiting for the containers to become healthy'
    if (Test-Endpoint -Url 'http://localhost:8080/healthz') {
        Write-Ok 'Flask container answers on http://localhost:8080'
    } else {
        Write-WarnMsg 'The app did not answer in time. Check: docker compose logs -f'
    }

    Write-Step 'Container status'
    & docker compose ps
}

function Start-Kubernetes {
    Write-Step "Starting Kubernetes mode on context '$Profile'"
    & kubectl --context $Profile apply -f k8s.yaml
    if ($LASTEXITCODE -ne 0) { throw 'kubectl apply -f k8s.yaml failed.' }
    & kubectl --context $Profile apply -f hpa.yaml
    if ($LASTEXITCODE -ne 0) { throw 'kubectl apply -f hpa.yaml failed.' }

    Write-Step 'Waiting for the Flask rollout'
    & kubectl --context $Profile rollout status deployment/visitor-counter --timeout=240s
    if ($LASTEXITCODE -ne 0) { throw 'The Deployment did not become ready.' }

    Write-Step 'Current objects'
    & kubectl --context $Profile get deployments,pods,svc,hpa
    Write-Host ''

    Write-Step 'Opening the endpoint on http://localhost:8080'
    & "$ProjectRoot\failover\failover.ps1" -Action start -PrimaryContext $Profile
    Write-Ok 'Browser: http://localhost:8080'
    Write-Info 'Keep this PowerShell window open: the tunnel (port-forward) lives inside it.'
}

switch ($Mode) {
    'docker' { Start-Docker }
    'k8s' { Start-Kubernetes }
    'all' {
        Start-Docker
        Start-Kubernetes
    }
}

Write-Host @"

Useful commands
---------------
  docker compose ps                     container status
  docker compose logs -f flask          application logs
  kubectl get pods -l app=visitor-counter
  kubectl get hpa visitor-counter-hpa
  .\scripts\stop.ps1 -Mode <docker|k8s|all>

"@ -ForegroundColor Gray
