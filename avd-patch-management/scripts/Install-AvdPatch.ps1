#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Script 2 of 2. Runs on an AVD session host, installs the patch that applies
    to it, and reports the outcome.

.DESCRIPTION
    Designed to run unattended as SYSTEM from a scheduled task on every session
    host simultaneously. Each host works independently - there is no
    coordination between them, no shared lock and no ordering requirement - so
    a thousand hosts can run this at the same time.

    Sequence on each host:
      1. Identify the OS precisely (build, UBR, release, architecture)
      2. Read the manifest from blob storage using the VM's managed identity
      3. Select the entry matching this host
      4. Decide applicability - already patched hosts do nothing
      5. Download the .msu and verify its SHA256 before use
      6. Install with DISM, no restart
      7. Write a result report back to blob storage
      8. Optionally reboot inside the configured window

    Startup is jittered by default. A thousand hosts hitting one storage account
    at 02:00:00 is a self-inflicted throttling incident; spreading them over a
    few minutes costs nothing and avoids it.

.PARAMETER ConfigPath
    Path to patch-config.json. If omitted, values come from the parameters and
    the local install directory.

.PARAMETER StorageAccount
    Storage account holding the patches.

.PARAMETER Container
    Blob container holding the patches and manifest.

.PARAMETER ManifestPath
    Blob path of the manifest. Defaults to manifests/latest.json.

.PARAMETER MaxJitterSeconds
    Random delay before contacting storage. Set to 0 for interactive runs.

.PARAMETER Reboot
    Reboot automatically when the update requires it.

.PARAMETER RebootDelaySeconds
    Grace period before rebooting, during which signed-in users are warned.

.PARAMETER Force
    Install even if applicability checks say it is unnecessary.

.PARAMETER WhatIf
    Do everything except install and reboot.

.EXAMPLE
    ./Install-AvdPatch.ps1 -StorageAccount stavdpatch01 -Container patches -Verbose

.EXAMPLE
    ./Install-AvdPatch.ps1 -ConfigPath C:\ProgramData\AvdPatch\patch-config.json -Reboot

.NOTES
    Requires the Storage Blob Data Reader role for the VM's managed identity.
    Read-only is deliberate: a compromised session host must not be able to
    modify the patches other hosts will install.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$StorageAccount,
    [string]$Container,
    [string]$ManifestPath = 'manifests/latest.json',
    [string]$ManagedIdentityClientId,
    [string]$SasToken,
    [string]$CacheDirectory = 'C:\ProgramData\AvdPatch\cache',
    [string]$LogDirectory = 'C:\ProgramData\AvdPatch\logs',
    [ValidateRange(0, 3600)][int]$MaxJitterSeconds = 300,
    [ValidateRange(5, 240)][int]$InstallTimeoutMinutes = 90,
    [switch]$Reboot,
    [ValidateRange(0, 86400)][int]$RebootDelaySeconds = 300,
    [switch]$SkipReport,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The module sits next to the script when deployed by Register-PatchScheduledTask.ps1.
$modulePath = Join-Path $PSScriptRoot 'AvdPatch/AvdPatch.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    $modulePath = Join-Path $PSScriptRoot '../src/AvdPatch/AvdPatch.psd1'
}
Import-Module $modulePath -Force

# --------------------------------------------------------------------------
# Configuration and logging
# --------------------------------------------------------------------------

if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if (-not $StorageAccount) { $StorageAccount = $config.storage.accountName }
    if (-not $Container) { $Container = $config.storage.patchContainer }
    if (-not $ManagedIdentityClientId -and $config.storage.PSObject.Properties.Name -contains 'managedIdentityClientId') {
        $ManagedIdentityClientId = $config.storage.managedIdentityClientId
    }
}

if (-not $StorageAccount) { throw 'StorageAccount is required (parameter or config).' }
if (-not $Container) { throw 'Container is required (parameter or config).' }

$logFile = Join-Path $LogDirectory ("patch-install-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Initialize-PatchLog -Path $logFile | Out-Null

$runId = [guid]::NewGuid().ToString()
$startedAt = Get-Date

Write-PatchLog "=== AVD patch install starting (run $runId) ==="

# Result object is built up as the run proceeds so that every exit path,
# including failures, produces a complete report.
$result = [ordered]@{
    runId          = $runId
    computerName   = $env:COMPUTERNAME
    startedAt      = $startedAt.ToUniversalTime().ToString('o')
    completedAt    = $null
    status         = 'Unknown'
    action         = 'Unknown'
    reason         = $null
    kbId           = $null
    manifestCycle  = $null
    osBuild        = $null
    osUbrBefore    = $null
    displayVersion = $null
    rebootRequired = $false
    rebootIssued   = $false
    durationSeconds = 0
    error          = $null
}

function Complete-Run {
    param(
        [string]$Status,
        [string]$Action,
        [string]$Reason,
        [int]$ExitCode = 0
    )

    $result.status = $Status
    $result.action = $Action
    if ($Reason) { $result.reason = $Reason }
    $result.completedAt = (Get-Date).ToUniversalTime().ToString('o')
    $result.durationSeconds = [int]((Get-Date) - $startedAt).TotalSeconds

    Write-PatchLog "Result: $Status / $Action - $Reason"

    if (-not $SkipReport) {
        try {
            $reportDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
            $reportPath = "reports/$reportDate/$($env:COMPUTERNAME).json"
            Set-BlobFromText -StorageAccount $StorageAccount -Container $Container `
                -BlobPath $reportPath -Content (([pscustomobject]$result) | ConvertTo-Json -Depth 5) `
                -SasToken $SasToken -ClientId $ManagedIdentityClientId -Confirm:$false
            Write-PatchLog "Report written to $reportPath"
        }
        catch {
            # A failed report must never turn a successful patch into a failure.
            Write-PatchLog "Could not write the report to storage: $($_.Exception.Message)" -Level Warning
        }
    }

    Write-PatchLog "=== Finished in $($result.durationSeconds)s with exit code $ExitCode ==="
    exit $ExitCode
}

try {
    # ---- jitter -----------------------------------------------------------
    if ($MaxJitterSeconds -gt 0) {
        $jitter = Get-Random -Minimum 0 -Maximum $MaxJitterSeconds
        Write-PatchLog "Sleeping ${jitter}s of jitter to spread load across the fleet."
        Start-Sleep -Seconds $jitter
    }

    # ---- identify this host ----------------------------------------------
    $os = Get-SessionHostOsIdentity
    $result.osBuild = $os.FullBuild
    $result.osUbrBefore = $os.Ubr
    $result.displayVersion = $os.DisplayVersion

    Write-PatchLog "Host OS: $($os.Caption)"
    Write-PatchLog "  build=$($os.FullBuild) release=$($os.DisplayVersion) arch=$($os.Architecture) multiSession=$($os.IsMultiSession) edition=$($os.EditionId)"

    if (Test-PendingReboot) {
        # Installing on top of a pending servicing operation is a common cause
        # of slow or failed installs, so stop rather than compound it.
        Complete-Run -Status 'Skipped' -Action 'PendingReboot' `
            -Reason 'A reboot is already pending on this host. Reboot it, then re-run.' -ExitCode 3
    }

    # ---- manifest ---------------------------------------------------------
    Write-PatchLog "Reading manifest $Container/$ManifestPath"
    $manifestJson = Get-BlobText -StorageAccount $StorageAccount -Container $Container `
        -BlobPath $ManifestPath -SasToken $SasToken -ClientId $ManagedIdentityClientId
    $manifest = $manifestJson | ConvertFrom-Json

    $result.manifestCycle = $manifest.cycle
    Write-PatchLog "Manifest cycle $($manifest.cycle) generated $($manifest.generatedAt), $($manifest.updateCount) update(s)."

    # ---- select and decide ------------------------------------------------
    $entry = Select-ManifestEntry -Manifest $manifest -OsIdentity $os

    if ($entry) {
        $result.kbId = $entry.kbId
        Write-PatchLog "Matched manifest entry: $($entry.kbId) - $($entry.title)"
    }

    $decision = Test-UpdateApplicable -OsIdentity $os -ManifestEntry $entry -Force:$Force
    Write-PatchLog "Applicability: $($decision.Action) - $($decision.Reason)"

    if (-not $decision.Applicable) {
        # Not an error. A host that is already current is a success.
        Complete-Run -Status 'Success' -Action $decision.Action -Reason $decision.Reason -ExitCode 0
    }

    # ---- download and verify ---------------------------------------------
    if (-not (Test-Path -LiteralPath $CacheDirectory)) {
        New-Item -Path $CacheDirectory -ItemType Directory -Force | Out-Null
    }

    $localPath = Join-Path $CacheDirectory $entry.fileName
    $needsDownload = $true

    if (Test-Path -LiteralPath $localPath) {
        Write-PatchLog 'Found a cached copy; verifying before reuse.'
        if (Test-FileIntegrity -Path $localPath -ExpectedSha256 $entry.sha256 -ExpectedSize ([int64]$entry.sizeBytes)) {
            Write-PatchLog 'Cached copy is valid; skipping download.'
            $needsDownload = $false
        }
        else {
            Write-PatchLog 'Cached copy failed verification; discarding it.' -Level Warning
            Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($needsDownload) {
        Write-PatchLog "Downloading $($entry.blobPath) ($([math]::Round($entry.sizeBytes / 1MB, 1)) MB)"
        Save-BlobToFile -StorageAccount $StorageAccount -Container $Container `
            -BlobPath $entry.blobPath -Destination $localPath `
            -SasToken $SasToken -ClientId $ManagedIdentityClientId | Out-Null
    }

    # Hard gate. This runs as SYSTEM and hands the file to DISM, so an
    # unverified package is remote code execution on every session host.
    if (-not (Test-FileIntegrity -Path $localPath -ExpectedSha256 $entry.sha256 -ExpectedSize ([int64]$entry.sizeBytes))) {
        Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
        throw "Integrity check failed for $($entry.fileName). The package was NOT installed. Expected SHA256 $($entry.sha256)."
    }
    Write-PatchLog 'Package integrity verified.'

    # ---- install ----------------------------------------------------------
    Write-PatchLog "Installing $($entry.kbId) with DISM (timeout ${InstallTimeoutMinutes}m)..."
    $install = Install-MsuPackage -PackagePath $localPath -TimeoutMinutes $InstallTimeoutMinutes -WhatIf:$WhatIfPreference

    $result.rebootRequired = $install.RebootRequired
    Write-PatchLog "DISM exit $($install.ExitCode): $($install.Message) (took $($install.DurationSeconds)s)"

    if (-not $install.Success) {
        $result.error = $install.Message
        Complete-Run -Status 'Failed' -Action $install.Status -Reason $install.Message -ExitCode 1
    }

    # ---- reboot -----------------------------------------------------------
    if ($install.RebootRequired -and $Reboot -and -not $WhatIfPreference) {
        Write-PatchLog "Reboot required. Warning users and restarting in ${RebootDelaySeconds}s."

        # A multi-session host may have people working on it. shutdown.exe's
        # own message is what signed-in users actually see.
        $comment = "Security updates ($($entry.kbId)) have been installed. This session host will restart shortly. Please save your work and sign out."
        try {
            & "$env:WINDIR\System32\shutdown.exe" /r /t $RebootDelaySeconds /c $comment /d p:2:17 | Out-Null
            $result.rebootIssued = $true
            Write-PatchLog 'Reboot scheduled.'
        }
        catch {
            Write-PatchLog "Could not schedule the reboot: $($_.Exception.Message)" -Level Warning
        }
    }
    elseif ($install.RebootRequired) {
        Write-PatchLog 'Reboot required but -Reboot was not specified. The update completes on the next restart.' -Level Warning
    }

    Complete-Run -Status 'Success' -Action $install.Status -Reason $install.Message -ExitCode 0
}
catch {
    $result.error = $_.Exception.Message
    Write-PatchLog "Unhandled failure: $($_.Exception.Message)" -Level Error
    Write-PatchLog $_.ScriptStackTrace -Level Debug
    Complete-Run -Status 'Failed' -Action 'Error' -Reason $_.Exception.Message -ExitCode 1
}
