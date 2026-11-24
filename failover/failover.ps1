#Requires -Version 5.1
<#
.SYNOPSIS
    Failover controller for the Visitor Counter hybrid-cloud simulation.

.DESCRIPTION
    This project runs the SAME application in two separate Minikube clusters:

        vc-primary    = simulated private cloud (active)
        vc-secondary  = simulated public cloud (standby)

    Both clusters expose the app through a Kubernetes Service. On Windows the
    reliable way to reach a Minikube Service is a kubectl port-forward tunnel,
    so the "active application endpoint" of this project is:

        http://localhost:8080  ->  tunnel  ->  active cluster Service

    That single local endpoint is what makes failover real: only one tunnel can
    own local port 8080. A failover therefore:

        1. probes the active endpoint (GET /health),
        2. kills the tunnel to the failed cluster,
        3. opens a tunnel to the standby cluster on the SAME local port,
        4. verifies the page is served by the other cluster
           (the page and /health report "environment" from the ConfigMap, so the
           change of routing path is visible, not assumed).

    Nothing else is required for the switch: no DNS change, no cloud account.
    The limitation (this is a port-level switch, not a real global load balancer)
    is documented in failover/README.md.

.PARAMETER Action
    start    : open the tunnel to the primary cluster on LocalPort.
    status   : show which cluster is active and print its /health output.
    failover : move the active endpoint from primary to secondary.
    recover  : move the active endpoint back to primary (after it is healthy).
    watch    : monitor the active endpoint and fail over automatically after
               FailureThreshold consecutive failed probes.

.EXAMPLE
    .\failover.ps1 -Action start

.EXAMPLE
    .\failover.ps1 -Action watch -PollSeconds 5 -FailureThreshold 3

.EXAMPLE
    .\failover.ps1 -Action recover
#>
[CmdletBinding()]
param(
    [ValidateSet('start', 'status', 'failover', 'recover', 'watch')]
    [string]$Action = 'status',

    [string]$PrimaryContext = 'vc-primary',
    [string]$SecondaryContext = 'vc-secondary',

    [string]$Namespace = 'default',
    [string]$ServiceName = 'visitor-counter',

    # The port the browser uses. Keep it stable: it is the "active endpoint".
    [int]$LocalPort = 8080,

    # watch mode: failed probes in a row before switching over.
    [int]$FailureThreshold = 3,

    # watch mode: seconds between probes.
    [int]$PollSeconds = 5
)

$ErrorActionPreference = 'Stop'
$StateFile = Join-Path $PSScriptRoot '.active-tunnel.json'
$script:KubectlPath = $null

# ---------------------------------------------------------------------------
# Console helpers
# ---------------------------------------------------------------------------
function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    [OK]   $Message" -ForegroundColor Green }
function Write-WarnMsg { param([string]$Message) Write-Host "    [WARN] $Message" -ForegroundColor Yellow }
function Write-FailMsg { param([string]$Message) Write-Host "    [FAIL] $Message" -ForegroundColor Red }

function Get-KubectlPath {
    if (-not $script:KubectlPath) {
        $command = Get-Command kubectl -ErrorAction SilentlyContinue
        if (-not $command) {
            throw "kubectl was not found in PATH. Install kubectl and reopen PowerShell."
        }
        $script:KubectlPath = $command.Source
    }
    return $script:KubectlPath
}

# ---------------------------------------------------------------------------
# Active-tunnel state (which cluster currently owns localhost:8080)
# ---------------------------------------------------------------------------
function Read-State {
    if (-not (Test-Path $StateFile)) { return $null }
    try {
        return (Get-Content -Path $StateFile -Raw | ConvertFrom-Json)
    } catch {
        Write-WarnMsg "Could not read $StateFile - treating it as empty."
        return $null
    }
}

function Save-State {
    param([string]$Context, [int]$Port, [int]$ProcessId)
    $state = [ordered]@{
        context   = $Context
        port      = $Port
        processId = $ProcessId
        updatedAt = (Get-Date).ToString('s')
    }
    $state | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

function Remove-State {
    Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
}

function Get-ActiveContext {
    $state = Read-State
    if ($state -and $state.context) { return $state.context }
    return $null
}

# ---------------------------------------------------------------------------
# Health probe of the active endpoint
# ---------------------------------------------------------------------------
function Invoke-Probe {
    param([int]$Port = $LocalPort)

    $url = "http://127.0.0.1:$Port/health"
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
        $payload = $null
        try { $payload = $response.Content | ConvertFrom-Json } catch { }
        $environment = $null
        $pod = $null
        $visits = $null
        if ($payload) {
            $environment = $payload.environment
            $pod = $payload.pod
            $visits = $payload.visits
        }
        return [pscustomobject]@{
            Reachable   = $true
            Healthy     = ($response.StatusCode -eq 200)
            StatusCode  = $response.StatusCode
            Environment = $environment
            Pod         = $pod
            Visits      = $visits
            Error       = $null
        }
    } catch {
        # A 503 response also lands here (Redis unreachable, app degraded).
        $statusCode = $null
        if ($_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
        }
        return [pscustomobject]@{
            Reachable   = ($null -ne $statusCode)
            Healthy     = $false
            StatusCode  = $statusCode
            Environment = $null
            Pod         = $null
            Visits      = $null
            Error       = $_.Exception.Message
        }
    }
}

function Show-Probe {
    param($Probe, [string]$Title)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor White
    Write-Host "  endpoint    : http://localhost:$LocalPort/health"
    if ($Probe.Reachable) {
        Write-Host "  reachable   : yes (HTTP $($Probe.StatusCode))"
    } else {
        Write-Host "  reachable   : NO"
    }
    Write-Host "  environment : $($Probe.Environment)"
    Write-Host "  pod         : $($Probe.Pod)"
    Write-Host "  visits      : $($Probe.Visits)"
    if ($Probe.Error) { Write-Host "  error       : $($Probe.Error)" -ForegroundColor DarkYellow }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Tunnel management
# ---------------------------------------------------------------------------
function Stop-PortForwardProcesses {
    <#
        Kills kubectl port-forward processes that own our local port. Needed
        because a previous PowerShell window may have left a dead tunnel behind
        and Windows would then report "address already in use".
    #>
    $processes = Get-CimInstance Win32_Process -Filter "Name='kubectl.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*port-forward*' -and $_.CommandLine -like "*$($LocalPort):*" }

    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            Write-WarnMsg "Cleaned up leftover port-forward (PID $($process.ProcessId))."
        } catch {
            Write-WarnMsg "Could not stop PID $($process.ProcessId): $($_.Exception.Message)"
        }
    }
}

function Stop-ActiveTunnel {
    $state = Read-State
    if ($state -and $state.processId) {
        $process = Get-Process -Id $state.processId -ErrorAction SilentlyContinue
        if ($process) {
            try {
                Stop-Process -Id $state.processId -Force
                Write-Ok "Stopped the tunnel to '$($state.context)' (PID $($state.processId))."
            } catch {
                Write-WarnMsg "Could not stop PID $($state.processId): $($_.Exception.Message)"
            }
        }
    }
    Stop-PortForwardProcesses
    Remove-State
}

function Start-Tunnel {
    <#
        Opens "localhost:<Port> -> svc/<ServiceName>:80" for one cluster and
        waits until the app answers (HTTP 200 or 503 both prove the tunnel and
        the Service work; only a timeout is treated as failure).
    #>
    param(
        [string]$Context,
        [int]$Port = $LocalPort,
        [switch]$Track
    )

    $kubectl = Get-KubectlPath
    $stdoutLog = Join-Path $PSScriptRoot ".port-forward-$Port.log"
    $stderrLog = Join-Path $PSScriptRoot ".port-forward-$Port.err.log"

    $argumentList = @(
        '--context', $Context,
        '-n', $Namespace,
        'port-forward', "svc/$ServiceName", "$($Port):80",
        '--address', '127.0.0.1'
    )

    Write-Step "Opening tunnel: kubectl $($argumentList -join ' ')"
    $process = Start-Process -FilePath $kubectl `
        -ArgumentList $argumentList `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog

    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) {
            throw "port-forward exited early (code $($process.ExitCode)). See $stderrLog"
        }
        $probe = Invoke-Probe -Port $Port
        if ($probe.Reachable) {
            if ($Track) { Save-State -Context $Context -Port $Port -ProcessId $process.Id }
            Write-Ok "Tunnel is up: http://localhost:$Port (context $Context, PID $($process.Id))."
            return [pscustomobject]@{ Process = $process; Probe = $probe }
        }
        Start-Sleep -Seconds 1
    }

    try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
    throw "Timed out waiting for the app on context '$Context'. Check: kubectl --context $Context get pods"
}

function Test-ClusterApp {
    <#
        Non-destructive check used before a recovery: opens a temporary tunnel
        on a scratch port (LocalPort + 1) and probes it.
    #>
    param([string]$Context)

    $scratchPort = $LocalPort + 1
    try {
        $tunnel = Start-Tunnel -Context $Context -Port $scratchPort
        try {
            return $tunnel.Probe
        } finally {
            try { Stop-Process -Id $tunnel.Process.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
    } catch {
        return [pscustomobject]@{
            Reachable   = $false
            Healthy     = $false
            StatusCode  = $null
            Environment = $null
            Pod         = $null
            Visits      = $null
            Error       = $_.Exception.Message
        }
    }
}

function Test-ClusterReachable {
    param([string]$Context)
    $kubectl = Get-KubectlPath
    & $kubectl --context $Context get nodes --request-timeout=10s 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------------------
# Failover / recovery
# ---------------------------------------------------------------------------
function Invoke-Failover {
    param(
        [string]$FromContext,
        [string]$ToContext
    )

    Write-Step "FAILOVER: $FromContext  ->  $ToContext"
    $before = Invoke-Probe

    Stop-ActiveTunnel
    Start-Sleep -Seconds 2

    # Windows can need a moment before the old port is fully released.
    $attempt = 0
    $result = $null
    while ($attempt -lt 3 -and -not $result) {
        $attempt++
        try {
            $result = Start-Tunnel -Context $ToContext -Track
        } catch {
            Write-WarnMsg "Attempt $attempt failed: $($_.Exception.Message)"
            Stop-PortForwardProcesses
            Start-Sleep -Seconds 3
        }
    }
    if (-not $result) {
        throw "Failover failed: could not open a tunnel to '$ToContext'. The application is now UNAVAILABLE."
    }

    $after = $result.Probe
    Show-Probe -Probe $before -Title 'BEFORE failover (failed primary)'
    Show-Probe -Probe $after  -Title "AFTER failover (serving from $ToContext)"

    if ($after.Reachable) {
        Write-Ok "Traffic now reaches the secondary environment: $($after.Environment)"
        Write-WarnMsg "Redis is NOT replicated between the clusters, so the visit count restarts from the secondary's own value."
    }
    return $after
}

function Invoke-Recovery {
    Write-Step "RECOVERY: checking whether the primary cluster is healthy again"
    if (-not (Test-ClusterReachable -Context $PrimaryContext)) {
        Write-FailMsg "Context '$PrimaryContext' is not reachable. Start it with: minikube -p $PrimaryContext start"
        return $null
    }
    Write-Ok "Kubernetes API of '$PrimaryContext' answers."

    $primaryProbe = Test-ClusterApp -Context $PrimaryContext
    if (-not $primaryProbe.Reachable) {
        Write-FailMsg "The application in '$PrimaryContext' is not answering yet. Keep the secondary active and retry later."
        return $null
    }
    Write-Ok "Application in '$PrimaryContext' answers (environment: $($primaryProbe.Environment))."

    $active = Get-ActiveContext
    if ($active -eq $PrimaryContext) {
        Write-Ok "The primary cluster is already the active endpoint - nothing to do."
        Show-Probe -Probe (Invoke-Probe) -Title "ACTIVE ($PrimaryContext)"
        return $primaryProbe
    }

    Write-Step "Switching the active endpoint back to '$PrimaryContext'"
    Stop-ActiveTunnel
    Start-Sleep -Seconds 2
    $result = Start-Tunnel -Context $PrimaryContext -Track
    $after = $result.Probe

    Show-Probe -Probe $after -Title "AFTER recovery ($PrimaryContext)"
    Write-Ok "Recovery complete: the primary environment serves http://localhost:$LocalPort again."
    Write-WarnMsg "Visit counters in the two clusters are independent; after recovery you see the primary's own count."
    return $after
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
function Show-Status {
    $active = Get-ActiveContext
    Write-Step "Active endpoint: http://localhost:$LocalPort"
    if (-not $active) {
        Write-WarnMsg "No tunnel is tracked. Start one with: .\failover.ps1 -Action start"
    } else {
        Write-Ok "Tracked context: $active"
    }

    $probe = Invoke-Probe
    Show-Probe -Probe $probe -Title 'CURRENT /health'

    Write-Host "  Configured contexts:" -ForegroundColor White
    $kubectl = Get-KubectlPath
    & $kubectl config get-contexts $PrimaryContext, $SecondaryContext 2>&1 | ForEach-Object { Write-Host "    $_" }
    Write-Host ""
}

switch ($Action) {
    'status' {
        Show-Status
    }

    'start' {
        if (Get-ActiveContext) {
            Write-WarnMsg "A tunnel is already tracked as active. Stopping it first."
            Stop-ActiveTunnel
        } else {
            Stop-PortForwardProcesses
        }
        $result = Start-Tunnel -Context $PrimaryContext -Track
        Show-Probe -Probe $result.Probe -Title "ACTIVE ($PrimaryContext)"
        Write-Host "  Open http://localhost:$LocalPort in the browser." -ForegroundColor White
        Write-Host ""
    }

    'failover' {
        $active = Get-ActiveContext
        if ($active -eq $SecondaryContext) {
            Write-Ok "The secondary environment is already active - nothing to do."
            Show-Probe -Probe (Invoke-Probe) -Title "ACTIVE ($SecondaryContext)"
            break
        }
        if (-not $active) {
            Write-WarnMsg "No tracked tunnel - assuming the primary was active."
        }
        Invoke-Failover -FromContext $PrimaryContext -ToContext $SecondaryContext | Out-Null
    }

    'recover' {
        Invoke-Recovery | Out-Null
    }

    'watch' {
        Write-Step "Watching http://localhost:$LocalPort every $PollSeconds s (Ctrl+C to stop)"
        Write-Host "    Failover happens after $FailureThreshold consecutive failed probes." -ForegroundColor DarkGray

        if (-not (Get-ActiveContext)) {
            Write-WarnMsg "No tracked tunnel. Opening one to '$PrimaryContext' first."
            Start-Tunnel -Context $PrimaryContext -Track | Out-Null
        }

        $failures = 0
        while ($true) {
            $probe = Invoke-Probe
            $active = Get-ActiveContext
            $timestamp = (Get-Date).ToString('HH:mm:ss')

            if ($probe.Healthy) {
                $failures = 0
                Write-Host "[$timestamp] OK      $active  env=$($probe.Environment)  pod=$($probe.Pod)  visits=$($probe.Visits)" -ForegroundColor Green
            } else {
                $failures++
                Write-Host "[$timestamp] FAILED  $active  ($failures/$FailureThreshold)  $($probe.Error)" -ForegroundColor Yellow
            }

            if ($failures -ge $FailureThreshold) {
                if ($active -eq $SecondaryContext) {
                    Write-FailMsg "The secondary environment is not answering either. Check: minikube status"
                } else {
                    Invoke-Failover -FromContext $active -ToContext $SecondaryContext | Out-Null
                    Write-WarnMsg "Primary failed. Run '.\failover.ps1 -Action recover' after you restart it."
                }
                $failures = 0
            }

            if ($active -eq $SecondaryContext -and $probe.Healthy) {
                $primaryProbe = Test-ClusterReachable -Context $PrimaryContext
                if ($primaryProbe) {
                    Write-Host "        (primary cluster is reachable again - run '.\failover.ps1 -Action recover' to switch back)" -ForegroundColor DarkGray
                }
            }

            Start-Sleep -Seconds $PollSeconds
        }
    }
}
