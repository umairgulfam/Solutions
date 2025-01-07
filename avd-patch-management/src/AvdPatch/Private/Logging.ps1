#Requires -Version 5.1

<#
    Logging.

    Every run writes to three places, because each answers a different question:
      file   - what happened on this host, readable during an incident
      event log - visible to whatever agent already monitors the fleet
      blob   - the fleet-wide compliance record, written by the caller

    The event log source is created on first use, which needs elevation. The
    installer runs as SYSTEM so that is satisfied; if it is not, logging
    degrades to file only rather than failing the patch run.
#>

$script:LogPath = $null
$script:EventLogSource = 'AvdPatchManagement'
$script:EventLogName = 'Application'
$script:EventLogAvailable = $null

function Initialize-PatchLog {
    <#
    .SYNOPSIS
        Sets the log file for this run and rotates old logs.

    .PARAMETER Path
        Full path to the log file.

    .PARAMETER RetentionDays
        Logs older than this are deleted from the same directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$RetentionDays = 90
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $script:LogPath = $Path

    if ($RetentionDays -gt 0 -and $directory -and (Test-Path -LiteralPath $directory)) {
        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        Get-ChildItem -Path $directory -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    return $script:LogPath
}

function Write-PatchLog {
    <#
    .SYNOPSIS
        Writes a structured log line to file, console and the event log.

    .PARAMETER Message
        The message.

    .PARAMETER Level
        Information, Warning or Error.

    .PARAMETER EventId
        Event log ID. Defaults by level so dashboards can filter.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet('Information', 'Warning', 'Error', 'Debug')]
        [string]$Level = 'Information',

        [int]$EventId = 0,

        [switch]$NoEventLog
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = '[{0}] [{1,-11}] [{2}] {3}' -f $timestamp, $Level, $env:COMPUTERNAME, $Message

    switch ($Level) {
        'Error' { Write-Error $Message -ErrorAction Continue }
        'Warning' { Write-Warning $Message }
        'Debug' { Write-Verbose $Message }
        default { Write-Information $Message -InformationAction Continue }
    }

    if ($script:LogPath) {
        try {
            Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not write to log file '$script:LogPath': $($_.Exception.Message)"
        }
    }

    if ($NoEventLog -or $Level -eq 'Debug') { return }
    if (-not $script:IsWindowsPlatform) { return }

    if ($EventId -eq 0) {
        $EventId = switch ($Level) { 'Error' { 9002 } 'Warning' { 9001 } default { 9000 } }
    }

    Write-PatchEventLog -Message $Message -Level $Level -EventId $EventId
}

function Write-PatchEventLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [string]$Level = 'Information',
        [int]$EventId = 9000
    )

    if ($null -eq $script:EventLogAvailable) {
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists($script:EventLogSource)) {
                # Needs elevation. SYSTEM has it; a user-context test run may not.
                New-EventLog -LogName $script:EventLogName -Source $script:EventLogSource -ErrorAction Stop
            }
            $script:EventLogAvailable = $true
        }
        catch {
            Write-Verbose "Event log unavailable, continuing with file logging only: $($_.Exception.Message)"
            $script:EventLogAvailable = $false
        }
    }

    if (-not $script:EventLogAvailable) { return }

    $entryType = switch ($Level) {
        'Error' { 'Error' }
        'Warning' { 'Warning' }
        default { 'Information' }
    }

    try {
        Write-EventLog -LogName $script:EventLogName -Source $script:EventLogSource `
            -EventId $EventId -EntryType $entryType -Message $Message -ErrorAction Stop
    }
    catch {
        Write-Verbose "Could not write event log entry: $($_.Exception.Message)"
    }
}

function Get-IsWindowsPlatform {
    <#
    .SYNOPSIS
        True on Windows, on both Windows PowerShell 5.1 and PowerShell 7.

    .DESCRIPTION
        $IsWindows only exists in PowerShell 6+. In 5.1 it is undefined, and 5.1
        only runs on Windows, so an undefined value means Windows.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($null -eq (Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue)) {
        return $true
    }
    return [bool]$IsWindows
}

# Evaluated once at import; used by Write-PatchLog to decide about the event log.
$script:IsWindowsPlatform = Get-IsWindowsPlatform
