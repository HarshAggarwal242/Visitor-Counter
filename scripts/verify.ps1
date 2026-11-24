#Requires -Version 5.1
<#
.SYNOPSIS
    Verify the Visitor Counter project end to end.

.DESCRIPTION
    Runs a series of read-only checks and prints PASS/FAIL for each one:
    tooling, Docker image, Compose stack, HTTP endpoints, Kubernetes objects,
    metrics-server, HPA, both clusters and the report artefacts.

    The script never modifies anything; it only inspects. Exit code is 0 when
    every check passed, 1 otherwise (useful for CI or for the report).

.EXAMPLE
    .\scripts\verify.ps1

.EXAMPLE
    .\scripts\verify.ps1 -Mode k8s
#>
[CmdletBinding()]
param(
    [ValidateSet('docker', 'k8s', 'all')]
    [string]$Mode = 'all',

    [string]$PrimaryProfile = 'vc-primary',
    [string]$SecondaryProfile = 'vc-secondary',
    [string]$DockerUrl = 'http://localhost:8080'
)

$ErrorActionPreference = 'Continue'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Check,
        [bool]$Passed,
        [string]$Detail = ''
    )
    $status = 'FAIL'
    $color = 'Red'
    if ($Passed) { $status = 'PASS'; $color = 'Green' }
    $results.Add([pscustomobject]@{ Component = $Check; Status = $status; Detail = $Detail })
    Write-Host ("  [{0}] {1,-42} {2}" -f $status, $Check, $Detail) -ForegroundColor $color
}

function Write-Section { param([string]$Title) Write-Host "`n--- $Title ---" -ForegroundColor Cyan }

function Invoke-Check {
    param(
        [string]$Check,
        [string]$Exe,
        [string[]]$Arguments
    )
    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) {
        Add-Result -Check $Check -Passed $false -Detail "$Exe not found"
        return
    }
    $output = & $Exe @Arguments 2>&1
    $ok = ($LASTEXITCODE -eq 0)
    $detail = ($output | Select-Object -First 1)
    if ($detail -isnot [string]) { $detail = "$detail" }
    Add-Result -Check $Check -Passed $ok -Detail $detail.Trim()
}

function Test-HttpEndpoint {
    param([string]$Check, [string]$Url)
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 8
        Add-Result -Check $Check -Passed ($response.StatusCode -eq 200) -Detail "HTTP $($response.StatusCode) from $Url"
        return $response
    } catch {
        $code = 'no response'
        if ($_.Exception.Response) { $code = "HTTP $([int]$_.Exception.Response.StatusCode)" }
        Add-Result -Check $Check -Passed $false -Detail "$code from $Url"
        return $null
    }
}

# ---------------------------------------------------------------------------
Write-Section 'Tooling'
Invoke-Check -Check 'python available' -Exe 'python' -Arguments @('--version')
Invoke-Check -Check 'docker available' -Exe 'docker' -Arguments @('version', '--format', '{{.Server.Version}}')
Invoke-Check -Check 'docker compose available' -Exe 'docker' -Arguments @('compose', 'version', '--short')
Invoke-Check -Check 'kubectl available' -Exe 'kubectl' -Arguments @('version', '--client')
Invoke-Check -Check 'minikube available' -Exe 'minikube' -Arguments @('version')

# ---------------------------------------------------------------------------
Write-Section 'Python application files'
foreach ($file in @('app.py', 'requirements.txt', 'Dockerfile', 'docker-compose.yml', 'k8s.yaml', 'hpa.yaml', 'load_test.py')) {
    Add-Result -Check "file $file exists" -Passed (Test-Path (Join-Path $ProjectRoot $file)) -Detail $file
}
& python -m py_compile app.py 2>&1 | Out-Null
Add-Result -Check 'python syntax of app.py' -Passed ($LASTEXITCODE -eq 0) -Detail 'py_compile'
& python -m py_compile load_test.py 2>&1 | Out-Null
Add-Result -Check 'python syntax of load_test.py' -Passed ($LASTEXITCODE -eq 0) -Detail 'py_compile'

# ---------------------------------------------------------------------------
if ($Mode -in @('docker', 'all')) {
    Write-Section 'Docker image'
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $imageSize = & docker image inspect visitor-counter:optimized --format '{{.Size}}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $imageSize) {
            $sizeMb = [math]::Round(([double]$imageSize) / 1MB, 1)
            Add-Result -Check 'image visitor-counter:optimized' -Passed $true -Detail "$sizeMb MB"
        } else {
            Add-Result -Check 'image visitor-counter:optimized' -Passed $false -Detail 'not built'
        }
    }

    Write-Section 'Docker Compose stack'
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $composePs = & docker compose ps --format '{{.Name}} {{.State}}' 2>&1
        $running = ($composePs -join ' ') -match 'running'
        Add-Result -Check 'compose containers running' -Passed $running -Detail (($composePs -join '; ') -replace '\s+', ' ')
    }

    Write-Section 'HTTP endpoints (Docker Compose)'
    Test-HttpEndpoint -Check 'GET / is served' -Url "$DockerUrl/" | Out-Null
    $health = Test-HttpEndpoint -Check 'GET /health is healthy' -Url "$DockerUrl/health"
    if ($health) {
        try {
            $payload = $health.Content | ConvertFrom-Json
            Add-Result -Check 'Redis reachable from Flask' -Passed ($payload.redis -eq 'ok') -Detail "visits=$($payload.visits)"
        } catch {
            Add-Result -Check 'Redis reachable from Flask' -Passed $false -Detail 'invalid JSON'
        }
    }
}

# ---------------------------------------------------------------------------
if ($Mode -in @('k8s', 'all')) {
    Write-Section "Kubernetes - primary cluster ($PrimaryProfile)"
    if (Get-Command kubectl -ErrorAction SilentlyContinue) {
        Invoke-Check -Check 'context exists' -Exe 'kubectl' -Arguments @('config', 'get-contexts', $PrimaryProfile)

        $nodes = & kubectl --context $PrimaryProfile get nodes --no-headers 2>$null
        Add-Result -Check 'node Ready' -Passed (($nodes -join ' ') -match ' Ready') -Detail (($nodes | Select-Object -First 1))

        $deploy = & kubectl --context $PrimaryProfile get deployment visitor-counter -o jsonpath='{.status.availableReplicas}' 2>$null
        Add-Result -Check 'Flask deployment available' -Passed ([int]($deploy -replace '\D', '0') -gt 0) -Detail "availableReplicas=$deploy"

        $redisPods = & kubectl --context $PrimaryProfile get pods -l app=redis --no-headers 2>$null
        Add-Result -Check 'Redis pod running' -Passed (($redisPods -join ' ') -match 'Running') -Detail (($redisPods | Select-Object -First 1))

        $readyProbe = & kubectl --context $PrimaryProfile get pods -l app=visitor-counter -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>$null
        $allReady = $true
        foreach ($value in ($readyProbe -split ' ')) {
            if ($value -eq 'false') { $allReady = $false }
        }
        Add-Result -Check 'Flask pods ready' -Passed $allReady -Detail "ready flags: $readyProbe"

        $metrics = & kubectl --context $PrimaryProfile top pods -l app=visitor-counter --no-headers 2>&1
        Add-Result -Check 'metrics-server provides CPU data' -Passed ($LASTEXITCODE -eq 0) -Detail (($metrics | Select-Object -First 1))

        $hpa = & kubectl --context $PrimaryProfile get hpa visitor-counter-hpa --no-headers 2>&1
        $hpaOk = ($LASTEXITCODE -eq 0) -and (($hpa -join ' ') -notmatch '<unknown>')
        Add-Result -Check 'HPA reports CPU metrics' -Passed $hpaOk -Detail (($hpa -join ' ') -replace '\s+', ' ')

        $svcType = & kubectl --context $PrimaryProfile get svc visitor-counter -o jsonpath='{.spec.type}' 2>$null
        Add-Result -Check 'Flask Service exposed' -Passed ($svcType -eq 'NodePort') -Detail "type=$svcType"
    }

    Write-Section "Kubernetes - secondary cluster ($SecondaryProfile)"
    if (Get-Command kubectl -ErrorAction SilentlyContinue) {
        Invoke-Check -Check 'secondary context exists' -Exe 'kubectl' -Arguments @('config', 'get-contexts', $SecondaryProfile)
        $secondaryDeploy = & kubectl --context $SecondaryProfile get deployment visitor-counter -o jsonpath='{.status.availableReplicas}' 2>$null
        Add-Result -Check 'secondary Flask deployment available' -Passed ([int]($secondaryDeploy -replace '\D', '0') -gt 0) -Detail "availableReplicas=$secondaryDeploy"
        $secondaryLocation = & kubectl --context $SecondaryProfile get configmap visitor-counter-config -o jsonpath='{.data.APP_LOCATION}' 2>$null
        Add-Result -Check 'secondary environment label' -Passed ($secondaryLocation -eq 'secondary-simulated-public-cloud') -Detail "APP_LOCATION=$secondaryLocation"
    }
}

# ---------------------------------------------------------------------------
Write-Section 'Report artefacts'
Add-Result -Check 'reports/architecture.png' -Passed (Test-Path 'reports/architecture.png')
Add-Result -Check 'reports/project_report.pdf' -Passed (Test-Path 'reports/project_report.pdf')
Add-Result -Check 'reports/cost_analysis.csv' -Passed (Test-Path 'reports/cost_analysis.csv')
Add-Result -Check 'failover/failover.ps1' -Passed (Test-Path 'failover/failover.ps1')

# ---------------------------------------------------------------------------
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host "`n================ SUMMARY ================" -ForegroundColor Cyan
Write-Host ("  checks run : {0}" -f $results.Count)
Write-Host ("  passed     : {0}" -f ($results.Count - $failed.Count)) -ForegroundColor Green
Write-Host ("  failed     : {0}" -f $failed.Count) -ForegroundColor $(if ($failed.Count -gt 0) { 'Red' } else { 'Green' })
if ($failed.Count -gt 0) {
    Write-Host "`nFailed checks:" -ForegroundColor Red
    foreach ($item in $failed) {
        Write-Host ("  - {0} ({1})" -f $item.Component, $item.Detail) -ForegroundColor Red
    }
}
Write-Host "========================================`n" -ForegroundColor Cyan

if ($failed.Count -gt 0) { exit 1 }
exit 0
