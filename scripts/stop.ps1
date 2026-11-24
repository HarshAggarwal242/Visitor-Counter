#Requires -Version 5.1
<#
.SYNOPSIS
    Stop the Visitor Counter (Docker Compose and/or Kubernetes) and clean up.

.DESCRIPTION
    -Mode docker : docker compose down (keeps the Redis volume unless -RemoveData).
    -Mode k8s    : deletes the Kubernetes objects from the cluster and stops any
                   port-forward tunnel started by failover.ps1.
    -Mode all    : both.

    Clusters themselves keep running unless you pass -StopClusters.

.EXAMPLE
    .\scripts\stop.ps1

.EXAMPLE
    .\scripts\stop.ps1 -Mode all -RemoveData -StopClusters
#>
[CmdletBinding()]
param(
    [ValidateSet('docker', 'k8s', 'all')]
    [string]$Mode = 'docker',

    [string]$Profile = 'vc-primary',
    [string]$SecondaryProfile = 'vc-secondary',

    [switch]$RemoveData,
    [switch]$StopClusters
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    [OK]   $Message" -ForegroundColor Green }
function Write-WarnMsg { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }

function Stop-Tunnels {
    # Close kubectl port-forward processes created by failover.ps1.
    $processes = Get-CimInstance Win32_Process -Filter "Name='kubectl.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*port-forward*' }
    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            Write-Ok "Closed port-forward PID $($process.ProcessId)"
        } catch {
            Write-WarnMsg "Could not stop PID $($process.ProcessId)"
        }
    }
    Remove-Item -Path (Join-Path $ProjectRoot 'failover\.active-tunnel.json') -Force -ErrorAction SilentlyContinue
}

function Stop-Docker {
    Write-Step 'Stopping the Docker Compose stack'
    if ($RemoveData) {
        Write-WarnMsg 'Redis volume will be deleted (-RemoveData): the visit count is lost.'
        & docker compose down -v
    } else {
        & docker compose down
    }
    if ($LASTEXITCODE -ne 0) { Write-WarnMsg "docker compose down exited with code $LASTEXITCODE" }
    Write-Ok 'Compose stack stopped (Redis volume kept).'
}

function Stop-Kubernetes {
    Write-Step "Deleting the Kubernetes objects from '$Profile'"
    & kubectl --context $Profile delete -f hpa.yaml --ignore-not-found
    & kubectl --context $Profile delete -f k8s.yaml --ignore-not-found
    Write-Ok 'Kubernetes objects deleted.'

    Write-Step 'Closing open tunnels'
    Stop-Tunnels
}

switch ($Mode) {
    'docker' { Stop-Docker }
    'k8s' { Stop-Kubernetes }
    'all' {
        Stop-Docker
        Stop-Kubernetes
    }
}

if ($StopClusters) {
    Write-Step 'Stopping both Minikube clusters'
    & minikube stop -p $Profile
    & minikube stop -p $SecondaryProfile
    Write-Ok 'Clusters stopped. Start them again with: minikube start -p <profile>'
}

Write-Host @"

Done. Notes
-----------
  * "docker compose down" keeps the named volume visitor-counter-redis-data,
    so the counter survives a restart.
  * "kubectl delete -f k8s.yaml" also deletes the PVC. Use it only when you do
    not need the Kubernetes visit count any more.
  * Stop everything:  .\scripts\stop.ps1 -Mode all -StopClusters

"@ -ForegroundColor Gray
