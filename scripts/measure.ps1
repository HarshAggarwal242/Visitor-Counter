#Requires -Version 5.1
<#
.SYNOPSIS
    Measure the three cost optimizations and write reports/cost_analysis.csv.

.DESCRIPTION
    Every before/after value in the CSV is produced by a command in this script.
    Nothing is hard-coded as a result - only as an input (the manifests).

    Technique 1 - Docker image size
        docker image inspect <baseline>  vs  docker image inspect <optimized>

    Technique 2 - Kubernetes resource right-sizing
        Applies k8s-before.yaml (5 Pods, 500m CPU / 512Mi memory requests),
        samples "kubectl top pods", then applies k8s.yaml (2 Pods, 100m / 128Mi)
        and samples again. The measured idle usage shows how much of the old
        reservation was pure waste.

    Technique 3 - Replica / autoscaling optimization
        Idle replica count before (5 fixed, always on) vs after (HPA keeps 2).

    The cluster state after the script is the project's normal state
    (k8s.yaml + hpa.yaml applied).

.EXAMPLE
    .\scripts\measure.ps1

.EXAMPLE
    # Only measure the Kubernetes part (image already built)
    .\scripts\measure.ps1 -SkipDocker
#>
[CmdletBinding()]
param(
    [string]$Context = 'vc-primary',
    [string]$ImageName = 'visitor-counter:optimized',
    [string]$BaselineImage = 'visitor-counter:baseline',

    # Sampling of "kubectl top pods": N samples taken X seconds apart.
    [int]$Samples = 4,
    [int]$SampleIntervalSeconds = 10,

    [switch]$SkipDocker,
    [switch]$SkipKubernetes,

    [string]$OutputCsv = 'reports/cost_analysis.csv'
)

$ErrorActionPreference = 'Continue'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

if (-not (Test-Path 'reports')) { New-Item -ItemType Directory -Path 'reports' | Out-Null }

$rows = New-Object System.Collections.Generic.List[object]

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    [OK]   $Message" -ForegroundColor Green }
function Write-WarnMsg { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }

function Add-Row {
    param(
        [string]$Technique,
        [string]$Metric,
        [string]$Before,
        [string]$After,
        [string]$Improvement,
        [string]$Method,
        [string]$Explanation,
        [string]$Evidence
    )
    $rows.Add([pscustomobject]@{
        Technique        = $Technique
        Metric           = $Metric
        Before           = $Before
        After            = $After
        Improvement      = $Improvement
        MeasurementMethod = $Method
        Explanation      = $Explanation
        EvidenceStatus   = $Evidence
    })
}

function Get-Improvement {
    param([double]$Before, [double]$After)
    if ($Before -le 0) { return 'n/a' }
    $change = ($Before - $After) / $Before * 100
    return ('{0:N1}% reduction' -f $change)
}

# ---------------------------------------------------------------------------
# Value parsing helpers for "kubectl top" output
# ---------------------------------------------------------------------------
function ConvertTo-Millicores {
    param([string]$Value)
    if (-not $Value) { return 0.0 }
    if ($Value -match '^([0-9]+)n$') { return [double]$Matches[1] / 1000000 }
    if ($Value -match '^([0-9]+)u$') { return [double]$Matches[1] / 1000 }
    if ($Value -match '^([0-9]+)m$') { return [double]$Matches[1] }
    if ($Value -match '^([0-9.]+)$') { return [double]$Matches[1] * 1000 }
    return 0.0
}

function ConvertTo-Mebibytes {
    param([string]$Value)
    if (-not $Value) { return 0.0 }
    if ($Value -match '^([0-9]+)Ki$') { return [double]$Matches[1] / 1024 }
    if ($Value -match '^([0-9]+)Mi$') { return [double]$Matches[1] }
    if ($Value -match '^([0-9]+)Gi$') { return [double]$Matches[1] * 1024 }
    if ($Value -match '^([0-9]+)$') { return [double]$Matches[1] / 1MB }
    return 0.0
}

function Get-ImageSizeMb {
    param([string]$Image)
    $bytes = & docker image inspect $Image --format '{{.Size}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $bytes) { return $null }
    return [math]::Round(([double]$bytes) / 1MB, 1)
}

function Get-PodUsage {
    <#
        Averages "kubectl top pods" over N samples so a single noisy reading
        does not end up in the report.
    #>
    param([string]$ContextName)

    $cpuTotal = 0.0
    $memTotal = 0.0
    $podTotal = 0
    $valid = $false

    for ($i = 1; $i -le $Samples; $i++) {
        $lines = & kubectl --context $ContextName top pods -l app=visitor-counter --no-headers 2>$null
        if ($LASTEXITCODE -eq 0 -and $lines) {
            $cpuSample = 0.0
            $memSample = 0.0
            $podsInSample = 0
            foreach ($line in $lines) {
                $parts = ($line.Trim() -split '\s+')
                if ($parts.Count -ge 3) {
                    $cpuSample += (ConvertTo-Millicores $parts[1])
                    $memSample += (ConvertTo-Mebibytes $parts[2])
                    $podsInSample++
                }
            }
            if ($podsInSample -gt 0) {
                $valid = $true
                $cpuTotal += $cpuSample
                $memTotal += $memSample
                $podTotal += $podsInSample
            }
        } else {
            Write-WarnMsg "kubectl top failed (sample $i/$Samples). Is metrics-server ready?"
        }
        if ($i -lt $Samples) { Start-Sleep -Seconds $SampleIntervalSeconds }
    }

    if (-not $valid) {
        return [pscustomobject]@{ Valid = $false; CpuPerPod = 0.0; MemPerPod = 0.0; CpuTotal = 0.0; MemTotal = 0.0; Replicas = 0.0 }
    }

    return [pscustomobject]@{
        Valid     = $true
        CpuPerPod = [math]::Round($cpuTotal / $podTotal, 1)
        MemPerPod = [math]::Round($memTotal / $podTotal, 1)
        CpuTotal  = [math]::Round($cpuTotal / $Samples, 1)
        MemTotal  = [math]::Round($memTotal / $Samples, 1)
        Replicas  = [math]::Round($podTotal / $Samples, 1)
    }
}

function Get-DeploymentValue {
    param([string]$ContextName, [string]$JsonPath)
    $value = & kubectl --context $ContextName get deployment visitor-counter -o "jsonpath=$JsonPath" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $value) { return $null }
    return ($value | Out-String).Trim()
}

# ===========================================================================
# Technique 1 - Docker image size
# ===========================================================================
Write-Step 'Technique 1: Docker image size'

$beforeImageMb = $null
$afterImageMb = $null

if (-not $SkipDocker) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-WarnMsg 'docker not found - image sizes marked as PENDING_MEASUREMENT.'
    } else {
        Write-Host '    building the baseline image (this takes a few minutes)...' -ForegroundColor Gray
        & docker build -f Dockerfile.baseline -t $BaselineImage . | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-WarnMsg 'Baseline image build failed.' }

        Write-Host '    building the optimized image...' -ForegroundColor Gray
        & docker build -f Dockerfile -t $ImageName . | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-WarnMsg 'Optimized image build failed.' }

        $beforeImageMb = Get-ImageSizeMb -Image $BaselineImage
        $afterImageMb = Get-ImageSizeMb -Image $ImageName
        if ($beforeImageMb) { Write-Ok "baseline  : $beforeImageMb MB" }
        if ($afterImageMb) { Write-Ok "optimized : $afterImageMb MB" }
    }
} else {
    Write-WarnMsg 'Skipped (-SkipDocker).'
}

if ($beforeImageMb -and $afterImageMb) {
    Add-Row -Technique 'Docker image optimization' `
        -Metric 'Image size (MB)' `
        -Before "$beforeImageMb MB (python:3.12, pip cache kept)" `
        -After "$afterImageMb MB (python:3.12-slim, no cache, non-root)" `
        -Improvement (Get-Improvement -Before $beforeImageMb -After $afterImageMb) `
        -Method 'docker image inspect <image> --format {{.Size}}' `
        -Explanation 'Smaller base image and no pip cache reduce image pull size, build time and registry storage.' `
        -Evidence 'measured'
} else {
    Add-Row -Technique 'Docker image optimization' `
        -Metric 'Image size (MB)' `
        -Before 'PENDING_MEASUREMENT' -After 'PENDING_MEASUREMENT' -Improvement 'PENDING' `
        -Method 'docker image inspect <image> --format {{.Size}}' `
        -Explanation 'Run this script on a machine with Docker Desktop to fill in the real sizes.' `
        -Evidence 'not_measured'
}

# ===========================================================================
# Techniques 2 and 3 - Kubernetes right-sizing and replicas
# ===========================================================================
$beforeUsage = $null
$afterUsage = $null
$beforeCpuRequest = $null
$afterCpuRequest = $null
$beforeMemRequest = $null
$afterMemRequest = $null
$beforeReplicas = $null
$afterReplicas = $null

if (-not $SkipKubernetes -and (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Step "Technique 2/3: baseline deployment on context '$Context'"
    try {
        & kubectl --context $Context get nodes --request-timeout=10s 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "context '$Context' is not reachable" }

        # The HPA must not fight with the fixed baseline replicas.
        & kubectl --context $Context delete -f hpa.yaml --ignore-not-found 2>&1 | Out-Null
        & kubectl --context $Context apply -f k8s-before.yaml 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'could not apply k8s-before.yaml' }
        & kubectl --context $Context rollout status deployment/visitor-counter --timeout=240s 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'baseline deployment did not become ready' }

        Start-Sleep -Seconds 20   # let metrics-server collect a few datapoints
        $beforeUsage = Get-PodUsage -ContextName $Context
        $beforeCpuRequest = Get-DeploymentValue -ContextName $Context -JsonPath '{.spec.template.spec.containers[0].resources.requests.cpu}'
        $beforeMemRequest = Get-DeploymentValue -ContextName $Context -JsonPath '{.spec.template.spec.containers[0].resources.requests.memory}'
        $beforeReplicas = Get-DeploymentValue -ContextName $Context -JsonPath '{.status.replicas}'
        Write-Ok "baseline: replicas=$beforeReplicas cpuRequest=$beforeCpuRequest memRequest=$beforeMemRequest"

        Write-Step 'Restoring the optimized configuration (k8s.yaml + hpa.yaml)'
        & kubectl --context $Context apply -f k8s.yaml 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'could not apply k8s.yaml' }
        & kubectl --context $Context apply -f hpa.yaml 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'could not apply hpa.yaml' }
        & kubectl --context $Context rollout status deployment/visitor-counter --timeout=240s 2>&1 | Out-Null
        Start-Sleep -Seconds 20

        $afterUsage = Get-PodUsage -ContextName $Context
        $afterCpuRequest = Get-DeploymentValue -ContextName $Context -JsonPath '{.spec.template.spec.containers[0].resources.requests.cpu}'
        $afterMemRequest = Get-DeploymentValue -ContextName $Context -JsonPath '{.spec.template.spec.containers[0].resources.requests.memory}'
        $afterReplicas = Get-DeploymentValue -ContextName $Context -JsonPath '{.status.replicas}'
        Write-Ok "optimized: replicas=$afterReplicas cpuRequest=$afterCpuRequest memRequest=$afterMemRequest"
    } catch {
        Write-WarnMsg "Kubernetes measurement failed: $($_.Exception.Message)"
        Write-WarnMsg 'The Kubernetes rows will be written as not_measured.'
    }
} else {
    Write-WarnMsg 'Skipped Kubernetes measurement (-SkipKubernetes or kubectl missing).'
}

$beforeCpuMc = 0.0
$afterCpuMc = 0.0
if ($beforeCpuRequest) { $beforeCpuMc = ConvertTo-Millicores $beforeCpuRequest }
if ($afterCpuRequest) { $afterCpuMc = ConvertTo-Millicores $afterCpuRequest }

if ($beforeUsage -and $beforeUsage.Valid -and $afterUsage -and $afterUsage.Valid) {
    $beforeTotalCpu = [math]::Round($beforeCpuMc * [double]$beforeReplicas, 0)
    $afterTotalCpu = [math]::Round($afterCpuMc * [double]$afterReplicas, 0)

    Add-Row -Technique 'Kubernetes resource right-sizing' `
        -Metric 'CPU request per Flask Pod (millicores)' `
        -Before "$beforeCpuMc m" -After "$afterCpuMc m" `
        -Improvement (Get-Improvement -Before $beforeCpuMc -After $afterCpuMc) `
        -Method 'kubectl get deployment visitor-counter -o jsonpath=...resources.requests.cpu (k8s-before.yaml vs k8s.yaml)' `
        -Explanation "The measured idle usage was $($beforeUsage.CpuPerPod) m CPU per Pod, so a 500m reservation was mostly unused; the request was right-sized to 100m." `
        -Evidence 'measured'

    Add-Row -Technique 'Kubernetes resource right-sizing' `
        -Metric 'Memory request per Flask Pod (MiB)' `
        -Before "$beforeMemRequest" -After "$afterMemRequest" `
        -Improvement 'see before/after' `
        -Method 'kubectl get deployment visitor-counter -o jsonpath=...resources.requests.memory' `
        -Explanation "Measured idle memory was $($beforeUsage.MemPerPod) MiB per Pod; 512Mi was reserved for a process that needs far less." `
        -Evidence 'measured'

    Add-Row -Technique 'Kubernetes resource right-sizing' `
        -Metric 'Total idle CPU reserved by the Flask Deployment (millicores)' `
        -Before "$beforeTotalCpu m ($beforeReplicas replicas x $beforeCpuMc m)" `
        -After "$afterTotalCpu m ($afterReplicas replicas x $afterCpuMc m)" `
        -Improvement (Get-Improvement -Before $beforeTotalCpu -After $afterTotalCpu) `
        -Method 'requests x running replicas, both read from kubectl' `
        -Explanation 'Reserved CPU cannot be used by other workloads; this is the number that maps to cluster cost.' `
        -Evidence 'measured'

    Add-Row -Technique 'Kubernetes resource right-sizing' `
        -Metric 'Measured idle CPU usage per Flask Pod (millicores)' `
        -Before "$($beforeUsage.CpuPerPod) m" -After "$($afterUsage.CpuPerPod) m" `
        -Improvement 'usage is unchanged - it shows the reservation was oversized' `
        -Method "kubectl top pods -l app=visitor-counter, averaged over $Samples samples" `
        -Explanation "The application needs about $($afterUsage.CpuPerPod) m CPU at idle; the old configuration reserved 500m per Pod." `
        -Evidence 'measured'

    Add-Row -Technique 'Kubernetes resource right-sizing' `
        -Metric 'Measured idle memory usage per Flask Pod (MiB)' `
        -Before "$($beforeUsage.MemPerPod) MiB" -After "$($afterUsage.MemPerPod) MiB" `
        -Improvement 'usage is unchanged - it shows the reservation was oversized' `
        -Method "kubectl top pods -l app=visitor-counter, averaged over $Samples samples" `
        -Explanation 'Idle memory usage justifies the 128Mi request.' `
        -Evidence 'measured'

    Add-Row -Technique 'Replica and autoscaling optimization' `
        -Metric 'Flask replicas running while idle' `
        -Before "$beforeReplicas (fixed, no HPA)" -After "$afterReplicas (HPA minReplicas=2)" `
        -Improvement (Get-Improvement -Before ([double]$beforeReplicas) -After ([double]$afterReplicas)) `
        -Method 'kubectl get deployment visitor-counter -o jsonpath={.status.replicas}' `
        -Explanation 'Idle traffic is served by 2 Pods; 5 always-on Pods were 3 Pods of pure waste. Under load the HPA still scales to 5.' `
        -Evidence 'measured'
} else {
    Add-Row -Technique 'Kubernetes resource right-sizing' `
        -Metric 'CPU request per Flask Pod (millicores)' `
        -Before 'PENDING_MEASUREMENT (500m configured in k8s-before.yaml)' `
        -After 'PENDING_MEASUREMENT (100m configured in k8s.yaml)' `
        -Improvement 'PENDING' `
        -Method 'kubectl get deployment visitor-counter -o jsonpath=...resources.requests.cpu' `
        -Explanation 'Run this script with a running cluster to collect the real numbers.' `
        -Evidence 'not_measured'

    Add-Row -Technique 'Kubernetes resource right-sizing' `
        -Metric 'Measured idle CPU / memory per Flask Pod' `
        -Before 'PENDING_MEASUREMENT' -After 'PENDING_MEASUREMENT' -Improvement 'PENDING' `
        -Method 'kubectl top pods -l app=visitor-counter' `
        -Explanation 'needs metrics-server: minikube addons enable metrics-server' `
        -Evidence 'not_measured'

    Add-Row -Technique 'Replica and autoscaling optimization' `
        -Metric 'Flask replicas running while idle' `
        -Before 'PENDING_MEASUREMENT (5 fixed in k8s-before.yaml)' `
        -After 'PENDING_MEASUREMENT (HPA minReplicas=2)' `
        -Improvement 'PENDING' `
        -Method 'kubectl get deployment visitor-counter -o jsonpath={.status.replicas}' `
        -Explanation 'Run this script with a running cluster to collect the real numbers.' `
        -Evidence 'not_measured'
}

# ===========================================================================
# Write the CSV
# ===========================================================================
function ConvertTo-CsvField {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value -match '[",\r\n]') {
        return '"' + $Value.Replace('"', '""') + '"'
    }
    return $Value
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('Technique,Metric,Before,After,Improvement,Measurement_Method,Explanation,Evidence_Status')
foreach ($row in $rows) {
    $fields = @(
        $row.Technique, $row.Metric, $row.Before, $row.After, $row.Improvement,
        $row.MeasurementMethod, $row.Explanation, $row.EvidenceStatus
    ) | ForEach-Object { ConvertTo-CsvField $_ }
    $lines.Add(($fields -join ','))
}

$outputPath = Join-Path $ProjectRoot $OutputCsv
$lines | Set-Content -Path $outputPath -Encoding UTF8
Write-Step "Cost analysis written to $OutputCsv"

$rows | Format-Table -Property Technique, Metric, Before, After, Improvement -AutoSize -Wrap
Write-Host ''
Write-WarnMsg 'Values marked not_measured/UNAVAILABLE mean the command could not run: rerun with Docker Desktop and the Minikube cluster active.'
Write-Host "`nCluster state: k8s.yaml + hpa.yaml are applied. Current objects:" -ForegroundColor Gray
& kubectl --context $Context get deployments,pods,hpa 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
