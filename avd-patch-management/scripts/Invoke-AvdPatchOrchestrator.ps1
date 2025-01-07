#Requires -Version 7.0

<#
.SYNOPSIS
    Optional orchestrator. Patches a host pool in batches, in parallel, with
    drain mode and user notification.

.DESCRIPTION
    There are two ways to run script 2 across a fleet, and they suit different
    environments:

    A. Scheduled task on every host (see deploy/Register-PatchScheduledTask.ps1)
       Every host patches itself at the same time. Simple, no orchestrator to
       maintain, no Azure permissions needed at run time, scales to any size.
       The catch is that every host reboots at roughly the same moment, so it
       suits pools that are genuinely idle overnight.

    B. This orchestrator
       Walks the pool in batches: drain, warn users, log off, patch, reboot,
       wait for healthy, move on. The pool stays partly available throughout.
       Use this when the pool serves users across time zones and can never be
       fully down.

    This script is B. It uses Invoke-AzVMRunCommand to execute script 2 on each
    host, which means it needs no inbound connectivity and no WinRM.

.PARAMETER ConfigPath
    Path to patch-config.json.

.PARAMETER HostPoolName
    Overrides orchestration.hostPoolName.

.PARAMETER ResourceGroupName
    Overrides orchestration.resourceGroupName.

.PARAMETER BatchPercentage
    Percentage of the pool to patch at once. 25 means four waves.

.PARAMETER DryRun
    Report what would happen without draining, patching or rebooting.

.EXAMPLE
    ./Invoke-AvdPatchOrchestrator.ps1 -DryRun

.EXAMPLE
    ./Invoke-AvdPatchOrchestrator.ps1 -BatchPercentage 20 -Verbose

.NOTES
    Requires PowerShell 7 for ForEach-Object -Parallel, plus the
    Az.DesktopVirtualization and Az.Compute modules. In Azure Automation use a
    runbook with the PowerShell 7.2 runtime.

    Required roles: Desktop Virtualization Contributor on the host pool and
    Virtual Machine Contributor on the session host VMs.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config/patch-config.json'),
    [string]$HostPoolName,
    [string]$ResourceGroupName,
    [ValidateRange(1, 100)][int]$BatchPercentage,
    [ValidateRange(1, 50)][int]$MaxParallelPerBatch,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../src/AvdPatch/AvdPatch.psd1') -Force

foreach ($required in @('Az.DesktopVirtualization', 'Az.Compute')) {
    if (-not (Get-Module -ListAvailable -Name $required)) {
        throw "Module '$required' is required but not installed. Install-Module $required -Scope CurrentUser"
    }
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$orch = $config.orchestration

if (-not $HostPoolName) { $HostPoolName = $orch.hostPoolName }
if (-not $ResourceGroupName) { $ResourceGroupName = $orch.resourceGroupName }
if (-not $BatchPercentage) { $BatchPercentage = [int]$orch.batchPercentage }
if (-not $MaxParallelPerBatch) { $MaxParallelPerBatch = [int]$orch.maxParallelPerBatch }

$logFile = Join-Path ([System.IO.Path]::GetTempPath()) ("avd-patch-orchestrator-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Initialize-PatchLog -Path $logFile | Out-Null

Write-PatchLog "=== Orchestrated patch run for host pool '$HostPoolName' ==="
Write-PatchLog "Batch size ${BatchPercentage}%, max $MaxParallelPerBatch in flight, DryRun=$DryRun"

# --------------------------------------------------------------------------
# Enumerate session hosts
# --------------------------------------------------------------------------

$sessionHosts = @(Get-AzWvdSessionHost -HostPoolName $HostPoolName -ResourceGroupName $ResourceGroupName)
if ($sessionHosts.Count -eq 0) {
    throw "Host pool '$HostPoolName' contains no session hosts."
}

Write-PatchLog "Found $($sessionHosts.Count) session host(s)."

# Session host names arrive as "hostpool/vmname.domain"; the VM name is what
# Invoke-AzVMRunCommand needs.
$targets = foreach ($sh in $sessionHosts) {
    $shortName = ($sh.Name -split '/')[-1]
    [pscustomobject]@{
        SessionHostName = $sh.Name
        VmName          = ($shortName -split '\.')[0]
        Status          = $sh.Status
        AllowNewSession = $sh.AllowNewSession
        Sessions        = $sh.Session
    }
}

$batchSize = [math]::Max(1, [math]::Ceiling($targets.Count * ($BatchPercentage / 100.0)))
$batches = for ($i = 0; $i -lt $targets.Count; $i += $batchSize) {
    , @($targets[$i..([math]::Min($i + $batchSize - 1, $targets.Count - 1))])
}

Write-PatchLog "Split into $($batches.Count) batch(es) of up to $batchSize host(s)."

$installScript = Join-Path $PSScriptRoot 'Install-AvdPatch.ps1'
if (-not (Test-Path -LiteralPath $installScript)) {
    throw "Cannot find Install-AvdPatch.ps1 at $installScript"
}

$allResults = [System.Collections.Generic.List[pscustomobject]]::new()
$batchNumber = 0

foreach ($batch in $batches) {
    $batchNumber++
    Write-PatchLog "--- Batch $batchNumber of $($batches.Count): $($batch.VmName -join ', ') ---"

    # ---- drain -----------------------------------------------------------
    foreach ($t in $batch) {
        if ($DryRun) {
            Write-PatchLog "[DryRun] Would set $($t.VmName) to drain mode."
            continue
        }
        if ($PSCmdlet.ShouldProcess($t.VmName, 'Enable drain mode')) {
            try {
                Update-AzWvdSessionHost -HostPoolName $HostPoolName -ResourceGroupName $ResourceGroupName `
                    -Name ($t.SessionHostName -split '/')[-1] -AllowNewSession:$false -ErrorAction Stop | Out-Null
                Write-PatchLog "$($t.VmName): drain mode on."
            }
            catch {
                Write-PatchLog "$($t.VmName): could not enable drain mode - $($_.Exception.Message)" -Level Warning
            }
        }
    }

    # ---- warn and evict users -------------------------------------------
    $grace = [int]$orch.drainGracePeriodMinutes
    $activeSessions = 0

    foreach ($t in $batch) {
        try {
            $sessions = @(Get-AzWvdUserSession -HostPoolName $HostPoolName -ResourceGroupName $ResourceGroupName `
                    -SessionHostName ($t.SessionHostName -split '/')[-1] -ErrorAction Stop)
            $activeSessions += $sessions.Count

            foreach ($session in $sessions) {
                if ($DryRun) {
                    Write-PatchLog "[DryRun] Would warn user on $($t.VmName)."
                    continue
                }
                Send-AzWvdUserSessionMessage -HostPoolName $HostPoolName -ResourceGroupName $ResourceGroupName `
                    -SessionHostName ($t.SessionHostName -split '/')[-1] `
                    -UserSessionId ($session.Name -split '/')[-1] `
                    -MessageTitle 'Scheduled maintenance' `
                    -MessageBody $orch.userWarningMessage -ErrorAction Stop
            }
        }
        catch {
            Write-PatchLog "$($t.VmName): could not enumerate or message sessions - $($_.Exception.Message)" -Level Warning
        }
    }

    if ($activeSessions -gt 0 -and -not $DryRun) {
        Write-PatchLog "$activeSessions active session(s) in this batch. Waiting ${grace} minute(s) for users to sign out."
        Start-Sleep -Seconds ($grace * 60)

        if ($orch.logOffUsersAfterGrace) {
            foreach ($t in $batch) {
                try {
                    $remaining = @(Get-AzWvdUserSession -HostPoolName $HostPoolName -ResourceGroupName $ResourceGroupName `
                            -SessionHostName ($t.SessionHostName -split '/')[-1] -ErrorAction Stop)
                    foreach ($session in $remaining) {
                        Write-PatchLog "$($t.VmName): signing out remaining session after grace period." -Level Warning
                        Remove-AzWvdUserSession -HostPoolName $HostPoolName -ResourceGroupName $ResourceGroupName `
                            -SessionHostName ($t.SessionHostName -split '/')[-1] `
                            -Id ($session.Name -split '/')[-1] -Force -ErrorAction Stop
                    }
                }
                catch {
                    Write-PatchLog "$($t.VmName): could not sign out sessions - $($_.Exception.Message)" -Level Warning
                }
            }
        }
    }

    # ---- patch in parallel ----------------------------------------------
    if ($DryRun) {
        Write-PatchLog "[DryRun] Would run Install-AvdPatch.ps1 on $($batch.Count) host(s) in parallel."
    }
    else {
        $rg = $ResourceGroupName
        $scriptPath = $installScript
        $storageAccount = $config.storage.accountName
        $container = $config.storage.patchContainer

        $batchResults = $batch | ForEach-Object -ThrottleLimit $MaxParallelPerBatch -Parallel {
            $vm = $_.VmName
            try {
                $params = @{
                    ResourceGroupName = $using:rg
                    VMName            = $vm
                    CommandId         = 'RunPowerShellScript'
                    ScriptPath        = $using:scriptPath
                    Parameter         = @{
                        StorageAccount   = $using:storageAccount
                        Container        = $using:container
                        MaxJitterSeconds = 0
                        Reboot           = $true
                    }
                }
                $response = Invoke-AzVMRunCommand @params -ErrorAction Stop
                $stdout = ($response.Value | Where-Object { $_.Code -match 'StdOut' }).Message

                [pscustomobject]@{
                    VmName  = $vm
                    Success = $true
                    Output  = $stdout
                    Error   = $null
                }
            }
            catch {
                [pscustomobject]@{
                    VmName  = $vm
                    Success = $false
                    Output  = $null
                    Error   = $_.Exception.Message
                }
            }
        }

        foreach ($r in $batchResults) {
            $allResults.Add($r)
            if ($r.Success) {
                Write-PatchLog "$($r.VmName): patch run completed."
            }
            else {
                Write-PatchLog "$($r.VmName): patch run FAILED - $($r.Error)" -Level Error
            }
        }
    }

    # ---- wait for hosts to come back ------------------------------------
    if (-not $DryRun -and $orch.rebootAfterInstall) {
        $timeout = [int]$orch.healthCheckTimeoutMinutes
        $deadline = (Get-Date).AddMinutes($timeout)
        Write-PatchLog "Waiting up to ${timeout}m for batch $batchNumber to report Available."

        do {
            Start-Sleep -Seconds 30
            $states = foreach ($t in $batch) {
                try {
                    (Get-AzWvdSessionHost -HostPoolName $HostPoolName -ResourceGroupName $ResourceGroupName `
                        -Name ($t.SessionHostName -split '/')[-1] -ErrorAction Stop).Status
                }
                catch { 'Unknown' }
            }
            $pending = @($states | Where-Object { $_ -ne 'Available' }).Count
        } while ($pending -gt 0 -and (Get-Date) -lt $deadline)

        if ($pending -gt 0) {
            # Continuing would compound an outage: the next batch would drain
            # while this one is still down.
            Write-PatchLog "$pending host(s) in batch $batchNumber are still not Available after ${timeout}m. Stopping so the pool does not lose further capacity." -Level Error
            break
        }
        Write-PatchLog "Batch $batchNumber is healthy."
    }

    # ---- re-enable sessions ---------------------------------------------
    foreach ($t in $batch) {
        if ($DryRun) {
            Write-PatchLog "[DryRun] Would re-enable new sessions on $($t.VmName)."
            continue
        }
        try {
            Update-AzWvdSessionHost -HostPoolName $HostPoolName -ResourceGroupName $ResourceGroupName `
                -Name ($t.SessionHostName -split '/')[-1] -AllowNewSession:$true -ErrorAction Stop | Out-Null
            Write-PatchLog "$($t.VmName): accepting new sessions again."
        }
        catch {
            # Leaving a host drained is a capacity incident the next morning.
            Write-PatchLog "$($t.VmName): FAILED to re-enable new sessions - $($_.Exception.Message). Re-enable this host manually." -Level Error
        }
    }
}

$succeeded = @($allResults | Where-Object { $_.Success }).Count
$failed = @($allResults | Where-Object { -not $_.Success }).Count

Write-PatchLog "=== Orchestration complete. $succeeded succeeded, $failed failed. Log: $logFile ==="

if ($failed -gt 0) { exit 1 }
exit 0
