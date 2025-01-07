#Requires -Version 5.1

<#
    Session host identification, applicability decisions and MSU installation.

    The applicability logic is the part worth reading carefully. Installing the
    wrong cumulative update is mostly harmless (Windows rejects it), but
    *skipping* one silently because the comparison was wrong means a host that
    reports success while staying vulnerable. Every decision here returns a
    reason string so the report says why, not just what.
#>

function Get-SessionHostOsIdentity {
    <#
    .SYNOPSIS
        Identifies the running OS precisely enough to select the right update.

    .DESCRIPTION
        Build number alone is not sufficient: Windows 11 22H2 and 23H2 share
        build 22621/22631 lineage and are serviced by different KBs. The
        DisplayVersion value (22H2, 23H2, 24H2) is the authoritative selector,
        with UBR giving the current patch level within that release.

    .OUTPUTS
        PSCustomObject with ComputerName, Caption, EditionId, BuildNumber, Ubr,
        DisplayVersion, Architecture, IsMultiSession and FullBuild.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $reg = Get-ItemProperty -Path $regPath -ErrorAction Stop

    $buildNumber = [int]$reg.CurrentBuildNumber
    $ubr = if ($null -ne $reg.UBR) { [int]$reg.UBR } else { 0 }

    # DisplayVersion replaced ReleaseId from 20H2 onward. Fall back for older builds.
    $displayVersion = if ($reg.PSObject.Properties.Name -contains 'DisplayVersion' -and $reg.DisplayVersion) {
        [string]$reg.DisplayVersion
    }
    elseif ($reg.PSObject.Properties.Name -contains 'ReleaseId' -and $reg.ReleaseId) {
        [string]$reg.ReleaseId
    }
    else {
        'unknown'
    }

    $caption = try {
        (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption
    }
    catch {
        [string]$reg.ProductName
    }

    $editionId = [string]$reg.EditionID

    $architecture = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x64' }
        'ARM64' { 'arm64' }
        'x86' { 'x86' }
        default { [string]$env:PROCESSOR_ARCHITECTURE }
    }

    # AVD multi-session reports EditionID ServerRdsh (Windows 10) or an
    # Enterprise multi-session caption (Windows 11). Checking both is more
    # reliable than either alone across releases.
    $isMultiSession = ($editionId -match 'ServerRdsh|EnterpriseMultiSession') -or
                      ($caption -match 'multi-session')

    return [pscustomobject]@{
        ComputerName   = $env:COMPUTERNAME
        Caption        = $caption
        EditionId      = $editionId
        BuildNumber    = $buildNumber
        Ubr            = $ubr
        FullBuild      = '{0}.{1}' -f $buildNumber, $ubr
        DisplayVersion = $displayVersion
        Architecture   = $architecture
        IsMultiSession = [bool]$isMultiSession
    }
}

function Test-KbInstalled {
    <#
    .SYNOPSIS
        Reports whether a KB is already present on this machine.

    .DESCRIPTION
        Checks two sources because neither is complete on its own. Get-HotFix
        wraps Win32_QuickFixEngineering, which misses updates delivered through
        the servicing stack on modern builds; Get-WindowsPackage sees those but
        needs elevation. Either saying yes is treated as installed.

    .PARAMETER KbId
        For example 'KB5043145'. The 'KB' prefix is optional.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$KbId
    )

    $normalised = $KbId.ToUpperInvariant()
    if ($normalised -notmatch '^KB') { $normalised = "KB$normalised" }
    $numeric = $normalised -replace '^KB', ''

    try {
        if (Get-HotFix -Id $normalised -ErrorAction SilentlyContinue) {
            Write-Verbose "$normalised found via Get-HotFix."
            return $true
        }
    }
    catch {
        Write-Verbose "Get-HotFix check failed: $($_.Exception.Message)"
    }

    try {
        $packages = Get-WindowsPackage -Online -ErrorAction Stop
        $match = $packages | Where-Object {
            $_.PackageName -match $numeric -and $_.PackageState -eq 'Installed'
        }
        if ($match) {
            Write-Verbose "$normalised found via Get-WindowsPackage."
            return $true
        }
    }
    catch {
        Write-Verbose "Get-WindowsPackage check failed (needs elevation): $($_.Exception.Message)"
    }

    return $false
}

function Select-ManifestEntry {
    <#
    .SYNOPSIS
        Finds the manifest entry matching a session host.

    .PARAMETER Manifest
        Deserialised manifest object produced by Invoke-PatchDownload.ps1.

    .PARAMETER OsIdentity
        Output of Get-SessionHostOsIdentity.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][pscustomobject]$OsIdentity
    )

    if (-not $Manifest.updates) {
        return $null
    }

    $matches = @($Manifest.updates | Where-Object {
            $_.buildNumber -eq $OsIdentity.BuildNumber -and
            $_.architecture -eq $OsIdentity.Architecture
        })

    # Narrow by DisplayVersion when the manifest carries one. Builds 22621 and
    # 22631 both exist under Windows 11 lineage, so this disambiguates.
    if ($matches.Count -gt 1) {
        $narrowed = @($matches | Where-Object {
                $_.displayVersion -and $_.displayVersion -eq $OsIdentity.DisplayVersion
            })
        if ($narrowed.Count -gt 0) { $matches = $narrowed }
    }

    if ($matches.Count -eq 0) { return $null }

    # If several remain, take the highest target UBR - that is the newest patch.
    return ($matches | Sort-Object -Property @{Expression = { [int]$_.targetUbr }; Descending = $true } | Select-Object -First 1)
}

function Test-UpdateApplicable {
    <#
    .SYNOPSIS
        Decides whether an update should be installed on this host.

    .OUTPUTS
        PSCustomObject with Applicable (bool), Reason (string) and Action.

    .NOTES
        Returns a reason in every branch. A patch report that says "skipped"
        without saying why is not auditable, and this output feeds the
        compliance report.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$OsIdentity,
        [Parameter()]$ManifestEntry,
        [switch]$Force
    )

    if ($null -eq $ManifestEntry) {
        return [pscustomobject]@{
            Applicable = $false
            Action     = 'NoUpdateAvailable'
            Reason     = "No update in the manifest matches build $($OsIdentity.FullBuild) $($OsIdentity.DisplayVersion) $($OsIdentity.Architecture)."
        }
    }

    if ($Force) {
        return [pscustomobject]@{
            Applicable = $true
            Action     = 'Install'
            Reason     = 'Force specified; applicability checks bypassed.'
        }
    }

    $targetUbr = [int]$ManifestEntry.targetUbr

    # UBR only increases within a build, so a host at or above the target is
    # already at least as patched as the update would make it.
    if ($targetUbr -gt 0 -and $OsIdentity.Ubr -ge $targetUbr) {
        return [pscustomobject]@{
            Applicable = $false
            Action     = 'AlreadyCurrent'
            Reason     = "Host is at UBR $($OsIdentity.Ubr), target is $targetUbr. Already at or beyond this update."
        }
    }

    if ($ManifestEntry.kbId -and (Test-KbInstalled -KbId $ManifestEntry.kbId)) {
        return [pscustomobject]@{
            Applicable = $false
            Action     = 'AlreadyInstalled'
            Reason     = "$($ManifestEntry.kbId) is already present on this host."
        }
    }

    return [pscustomobject]@{
        Applicable = $true
        Action     = 'Install'
        Reason     = "Host at UBR $($OsIdentity.Ubr) is below target UBR $targetUbr; $($ManifestEntry.kbId) not installed."
    }
}

function Get-FileSha256 {
    <#
    .SYNOPSIS
        SHA256 of a file, lowercase hex.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot hash '$Path' because it does not exist."
    }

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-FileIntegrity {
    <#
    .SYNOPSIS
        Verifies a downloaded file against its expected hash and size.

    .DESCRIPTION
        This is a security control, not a convenience. The installer runs as
        SYSTEM and hands the file to DISM, so anything that can write to the
        blob or intercept the transfer would otherwise get code execution on
        every session host. The hash is recorded at download time by script 1
        and checked here before a single byte reaches DISM.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [long]$ExpectedSize = 0
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Integrity check failed: '$Path' does not exist."
        return $false
    }

    if ($ExpectedSize -gt 0) {
        $actualSize = (Get-Item -LiteralPath $Path).Length
        if ($actualSize -ne $ExpectedSize) {
            Write-Warning "Integrity check failed: size $actualSize does not match expected $ExpectedSize."
            return $false
        }
    }

    $actualHash = Get-FileSha256 -Path $Path
    $expected = $ExpectedSha256.ToLowerInvariant()

    if ($actualHash -ne $expected) {
        Write-Warning "Integrity check failed: SHA256 $actualHash does not match expected $expected."
        return $false
    }

    Write-Verbose "Integrity verified for $Path."
    return $true
}

function Get-DismExitCodeInfo {
    <#
    .SYNOPSIS
        Translates a DISM exit code into a decision.

    .DESCRIPTION
        Treating "non-zero means failure" here would page someone every month:
        3010 is the normal, successful result for a cumulative update that needs
        a reboot, and "not applicable" is an expected outcome on a host that is
        already current.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$ExitCode
    )

    $map = @{
        0          = @{ S = 'Success';               R = $false; OK = $true;  M = 'Update installed successfully.' }
        3010       = @{ S = 'SuccessRebootRequired'; R = $true;  OK = $true;  M = 'Update installed. A reboot is required to complete it.' }
        1641       = @{ S = 'RebootInitiated';       R = $true;  OK = $true;  M = 'Update installed and a reboot was initiated.' }
        -2145124329 = @{ S = 'NotApplicable';        R = $false; OK = $true;  M = 'Update is not applicable to this host (0x80240017).' }
        -2146498530 = @{ S = 'NotApplicable';        R = $false; OK = $true;  M = 'Update is not applicable to this host (0x800F081E).' }
        2359302    = @{ S = 'AlreadyInstalled';      R = $false; OK = $true;  M = 'Update is already installed (0x00240006).' }
        -2145124330 = @{ S = 'AlreadyInstalled';     R = $false; OK = $true;  M = 'Update is already installed (0x80240016).' }
        1618       = @{ S = 'InstallerBusy';         R = $false; OK = $false; M = 'Another installation is already in progress. Retry later.' }
        -2145124322 = @{ S = 'InstallerBusy';        R = $false; OK = $false; M = 'Windows Update is busy (0x8024001E). Retry later.' }
        87         = @{ S = 'InvalidParameter';      R = $false; OK = $false; M = 'DISM rejected the parameters. Check the package path.' }
    }

    if ($map.ContainsKey($ExitCode)) {
        $entry = $map[$ExitCode]
        return [pscustomobject]@{
            ExitCode       = $ExitCode
            Status         = $entry.S
            RebootRequired = $entry.R
            Success        = $entry.OK
            Message        = $entry.M
        }
    }

    return [pscustomobject]@{
        ExitCode       = $ExitCode
        Status         = 'Failed'
        RebootRequired = $false
        Success        = $false
        Message        = "DISM returned unmapped exit code $ExitCode (0x{0:X8}). Check %WINDIR%\Logs\DISM\dism.log." -f $ExitCode
    }
}

function Install-MsuPackage {
    <#
    .SYNOPSIS
        Installs an .msu using DISM.

    .DESCRIPTION
        DISM rather than wusa.exe: wusa is deprecated for .msu on current
        Windows builds and its exit codes are less informative. /NoRestart is
        always passed because reboot timing is an orchestration decision, never
        the installer's - an unexpected restart mid-session on a multi-session
        host disconnects every user on it.

    .PARAMETER PackagePath
        Full path to the .msu.

    .PARAMETER TimeoutMinutes
        Cumulative updates on a cold servicing stack can legitimately take 45
        minutes. The default allows for that; the process is killed beyond it so
        a wedged install cannot hold the maintenance window open forever.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PackagePath,

        [ValidateRange(5, 240)]
        [int]$TimeoutMinutes = 90
    )

    if (-not (Test-Path -LiteralPath $PackagePath)) {
        throw "Package '$PackagePath' does not exist."
    }

    $dism = Join-Path $env:WINDIR 'System32\Dism.exe'
    $arguments = @(
        '/Online'
        '/Add-Package'
        "/PackagePath:`"$PackagePath`""
        '/Quiet'
        '/NoRestart'
        '/LogLevel:3'
    )

    if (-not $PSCmdlet.ShouldProcess($PackagePath, 'Install update package')) {
        return [pscustomobject]@{
            ExitCode = 0; Status = 'WhatIf'; RebootRequired = $false
            Success = $true; Message = 'WhatIf: installation skipped.'; DurationSeconds = 0
        }
    }

    Write-Verbose "Running: $dism $($arguments -join ' ')"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $process = Start-Process -FilePath $dism -ArgumentList $arguments -Wait:$false -PassThru -WindowStyle Hidden
    $completed = $process.WaitForExit($TimeoutMinutes * 60 * 1000)

    if (-not $completed) {
        try { $process.Kill() } catch { Write-Warning "Could not kill DISM: $($_.Exception.Message)" }
        $stopwatch.Stop()
        return [pscustomobject]@{
            ExitCode        = -1
            Status          = 'Timeout'
            RebootRequired  = $false
            Success         = $false
            Message         = "DISM did not finish within $TimeoutMinutes minutes and was terminated."
            DurationSeconds = [int]$stopwatch.Elapsed.TotalSeconds
        }
    }

    $stopwatch.Stop()
    $info = Get-DismExitCodeInfo -ExitCode $process.ExitCode

    return [pscustomobject]@{
        ExitCode        = $info.ExitCode
        Status          = $info.Status
        RebootRequired  = $info.RebootRequired
        Success         = $info.Success
        Message         = $info.Message
        DurationSeconds = [int]$stopwatch.Elapsed.TotalSeconds
    }
}

function Test-PendingReboot {
    <#
    .SYNOPSIS
        Reports whether Windows already has a reboot pending.

    .DESCRIPTION
        Worth checking before installing: stacking a cumulative update on top of
        an existing pending servicing operation is a common cause of failed or
        very slow installs.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $indicators = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'
    )

    foreach ($path in $indicators) {
        if (Test-Path -LiteralPath $path) {
            Write-Verbose "Pending reboot indicated by $path"
            return $true
        }
    }

    $pendingRename = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if ($pendingRename -and $pendingRename.PendingFileRenameOperations) {
        Write-Verbose 'Pending reboot indicated by PendingFileRenameOperations.'
        return $true
    }

    return $false
}
