#Requires -Version 5.1
<#
.SYNOPSIS
    One-time setup for the Visitor Counter cloud project.

.DESCRIPTION
    Checks the prerequisites, builds the Docker image, creates the two Minikube
    clusters (primary + secondary), loads the image into both, applies the
    Kubernetes manifests, gives the secondary cluster its own APP_LOCATION and
    waits for both deployments to become ready.

    Run it from anywhere; it always works in the project root.

.EXAMPLE
    .\scripts\setup.ps1

.EXAMPLE
    # Only rebuild the image and redeploy (clusters already exist)
    .\scripts\setup.ps1 -SkipClusters
#>
[CmdletBinding()]
param(
    [string]$PrimaryProfile = 'vc-primary',
    [string]$SecondaryProfile = 'vc-secondary',

    # Docker Desktop must have at least this much CPU/RAM available.
    [int]$PrimaryCpus = 4,
    [int]$PrimaryMemoryMb = 6144,
    [int]$SecondaryCpus = 2,
    [int]$SecondaryMemoryMb = 3584,

    [switch]$SkipClusters,
    [switch]$SkipImage
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

$ImageName = 'visitor-counter:optimized'

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    [OK]   $Message" -ForegroundColor Green }
function Write-WarnMsg { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }

function Invoke-Step {
    <#
        Runs an external command, shows it, and stops the script when it fails.
        Usage: Invoke-Step -Title "..." -Command @('docker','build','-t',$ImageName,'.')
    #>
    param(
        [string]$Title,
        [string[]]$Command,
        [switch]$AllowFailure
    )
    Write-Step $Title
    Write-Info ($Command -join ' ')

    $exe = $Command[0]
    $arguments = @()
    if ($Command.Length -gt 1) { $arguments = $Command[1..($Command.Length - 1)] }

    & $exe @arguments
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
        if ($AllowFailure) {
            Write-WarnMsg "Command exited with code $exit (allowed to continue)."
            return $false
        }
        throw "Command failed with exit code ${exit}: $($Command -join ' ')"
    }
    Write-Ok "done."
    return $true
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# Step 1 - prerequisites
# ---------------------------------------------------------------------------
Write-Step 'Checking prerequisites'
$missing = @()
foreach ($tool in @('docker', 'kubectl', 'minikube', 'python')) {
    if (Test-CommandExists $tool) {
        Write-Ok "$tool found: $((Get-Command $tool).Source)"
    } else {
        $missing += $tool
        Write-WarnMsg "$tool NOT found in PATH"
    }
}

if ($missing.Count -gt 0) {
    throw "Missing tools: $($missing -join ', '). Install them, reopen PowerShell and run this script again."
}

Invoke-Step -Title 'Docker Engine status' -Command @('docker', 'version', '--format', 'Server {{.Server.Version}}')
Invoke-Step -Title 'Docker Compose version' -Command @('docker', 'compose', 'version')
Invoke-Step -Title 'kubectl client version' -Command @('kubectl', 'version', '--client')
Invoke-Step -Title 'Minikube version' -Command @('minikube', 'version')
Invoke-Step -Title 'Python version' -Command @('python', '--version')

# ---------------------------------------------------------------------------
# Step 2 - build the application image
# ---------------------------------------------------------------------------
if (-not $SkipImage) {
    Invoke-Step -Title "Building the Docker image $ImageName" -Command @('docker', 'build', '-t', $ImageName, '.')
} else {
    Write-WarnMsg 'Skipping the image build (-SkipImage).'
}

# ---------------------------------------------------------------------------
# Step 3 - create both clusters
# ---------------------------------------------------------------------------
function Initialize-Cluster {
    param(
        [string]$Profile,
        [int]$Cpus,
        [int]$MemoryMb
    )

    $profiles = @()
    try {
        $profiles = (& minikube profile list -o json 2>$null | ConvertFrom-Json).valid
    } catch {
        $profiles = @()
    }
    $exists = $false
    foreach ($profile in $profiles) {
        if ($profile.Name -eq $Profile) { $exists = $true }
    }

    if ($exists) {
        Write-Ok "Minikube profile '$Profile' already exists - starting/verifying it."
        Invoke-Step -Title "Starting profile $Profile" -Command @('minikube', 'start', '-p', $Profile, '--driver=docker')
    } else {
        Invoke-Step -Title "Creating Minikube profile $Profile (${Cpus} CPUs, ${MemoryMb} MB)" -Command @(
            'minikube', 'start', '-p', $Profile, '--driver=docker', "--cpus=$Cpus", "--memory=$MemoryMb"
        )
    }

    Invoke-Step -Title "Enabling metrics-server on $Profile" -Command @('minikube', '-p', $Profile, 'addons', 'enable', 'metrics-server')

    Invoke-Step -Title "Loading the image into $Profile" -Command @('minikube', '-p', $Profile, 'image', 'load', $ImageName)
}

function Deploy-App {
    param([string]$Context)

    Invoke-Step -Title "Applying k8s.yaml to $Context" -Command @('kubectl', '--context', $Context, 'apply', '-f', 'k8s.yaml')
    Invoke-Step -Title "Applying hpa.yaml to $Context" -Command @('kubectl', '--context', $Context, 'apply', '-f', 'hpa.yaml')
    Invoke-Step -Title "Waiting for the rollout in $Context" -Command @(
        'kubectl', '--context', $Context, 'rollout', 'status', 'deployment/visitor-counter', '--timeout=240s'
    )
    Invoke-Step -Title "Waiting for Redis in $Context" -Command @(
        'kubectl', '--context', $Context, 'rollout', 'status', 'deployment/redis', '--timeout=240s'
    )
}

if (-not $SkipClusters) {
    # --- primary (simulated private cloud) ---
    Initialize-Cluster -Profile $PrimaryProfile -Cpus $PrimaryCpus -MemoryMb $PrimaryMemoryMb
    Deploy-App -Context $PrimaryProfile

    # --- secondary (simulated public cloud) ---
    Initialize-Cluster -Profile $SecondaryProfile -Cpus $SecondaryCpus -MemoryMb $SecondaryMemoryMb
    Deploy-App -Context $SecondaryProfile

    # The secondary must identify itself, otherwise both clusters look identical
    # in the failover demonstration.
    Invoke-Step -Title 'Labeling the secondary environment' -Command @(
        'kubectl', '--context', $SecondaryProfile, '-n', 'default', 'patch', 'configmap', 'visitor-counter-config',
        '--type', 'merge', '-p', '{"data":{"APP_LOCATION":"secondary-simulated-public-cloud"}}'
    )
    Invoke-Step -Title 'Restarting the Flask deployment in the secondary cluster' -Command @(
        'kubectl', '--context', $SecondaryProfile, 'rollout', 'restart', 'deployment/visitor-counter'
    )
    Invoke-Step -Title 'Waiting for the secondary rollout' -Command @(
        'kubectl', '--context', $SecondaryProfile, 'rollout', 'status', 'deployment/visitor-counter', '--timeout=240s'
    )
} else {
    Write-WarnMsg 'Skipping the Minikube cluster steps (-SkipClusters).'
}

# ---------------------------------------------------------------------------
# Step 4 - summary
# ---------------------------------------------------------------------------
Write-Step 'Setup finished'
Write-Host @"

Next steps
----------
1. Start the local Docker Compose stack (needed for the first half of the project):
       docker compose up -d --build
       start http://localhost:8080

2. Open the primary Kubernetes environment:
       .\failover\failover.ps1 -Action start
       start http://localhost:8080

3. Watch the autoscaler (two windows):
       kubectl --context $PrimaryProfile get hpa visitor-counter-hpa -w
       python load_test.py --url http://localhost:8080/ --workers 30 --duration 180

4. Hybrid cloud failover demonstration:
       cd failover
       .\failover.ps1 -Action watch

5. Cost measurements (writes reports\cost_analysis.csv):
       .\scripts\measure.ps1

"@ -ForegroundColor Gray
