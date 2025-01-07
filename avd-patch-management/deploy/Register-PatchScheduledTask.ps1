#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Installs the patch agent onto a session host and schedules it for the
    second Wednesday of every month.

.DESCRIPTION
    Copies Install-AvdPatch.ps1 and the AvdPatch module to a fixed location,
    then registers a scheduled task that runs as SYSTEM.

    The trigger is defined in task XML rather than with New-ScheduledTaskTrigger
    because the ScheduledTasks cmdlets cannot express "the second Wednesday of
    every month". The underlying Task Scheduler schema can, via
    ScheduleByMonthDayOfWeek, so the XML is registered directly.

    Default timing is the second WEDNESDAY, not Tuesday. Microsoft publishes on
    Tuesday, script 1 stages overnight, and hosts install the following night.
    Installing on Tuesday evening races the catalog publish and risks a cycle
    where half the fleet gets a manifest that does not exist yet.

    Bake this into the golden image so new session hosts arrive already
    enrolled, or run it via Run Command against an existing pool.

.PARAMETER StorageAccount
    Storage account holding the patches.

.PARAMETER Container
    Blob container holding the patches.

.PARAMETER InstallRoot
    Where the agent is installed.

.PARAMETER StartTime
    Local time of day to run, as HH:mm.

.PARAMETER WeekOfMonth
    Which occurrence of the day to use. SECOND matches Patch Tuesday + 1 day.

.PARAMETER DayOfWeek
    Day of week for the run.

.PARAMETER Reboot
    Pass -Reboot to the installer so hosts restart automatically.

.PARAMETER Unregister
    Remove the scheduled task and installed files.

.EXAMPLE
    ./Register-PatchScheduledTask.ps1 -StorageAccount stavdpatchprod01 -Container patches -Reboot

.EXAMPLE
    ./Register-PatchScheduledTask.ps1 -Unregister
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$StorageAccount,
    [string]$Container = 'patches',
    [string]$ManagedIdentityClientId,
    [string]$InstallRoot = 'C:\Program Files\AvdPatch',
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$StartTime = '02:00',
    [ValidateSet('FIRST', 'SECOND', 'THIRD', 'FOURTH', 'LAST')]
    [string]$WeekOfMonth = 'SECOND',
    [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
    [string]$DayOfWeek = 'Wednesday',
    [string]$TaskName = 'AVD Monthly Security Patching',
    [ValidateRange(0, 3600)][int]$MaxJitterSeconds = 300,
    [switch]$Reboot,
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$taskPath = '\Microsoft\AvdPatch\'

# --------------------------------------------------------------------------
# Uninstall
# --------------------------------------------------------------------------

if ($Unregister) {
    Write-Host "Removing scheduled task '$TaskName'..."
    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    if ($existing) {
        if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
            Unregister-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -Confirm:$false
            Write-Host 'Scheduled task removed.'
        }
    }
    else {
        Write-Host 'Scheduled task not found; nothing to remove.'
    }

    if (Test-Path -LiteralPath $InstallRoot) {
        if ($PSCmdlet.ShouldProcess($InstallRoot, 'Remove installed files')) {
            Remove-Item -LiteralPath $InstallRoot -Recurse -Force
            Write-Host "Removed $InstallRoot"
        }
    }
    exit 0
}

if (-not $StorageAccount) {
    throw 'StorageAccount is required when registering the task.'
}

# --------------------------------------------------------------------------
# Deploy files
# --------------------------------------------------------------------------

$sourceRoot = Split-Path -Path $PSScriptRoot -Parent
$sourceScript = Join-Path $sourceRoot 'scripts/Install-AvdPatch.ps1'
$sourceModule = Join-Path $sourceRoot 'src/AvdPatch'

foreach ($path in @($sourceScript, $sourceModule)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Expected to find '$path'. Run this script from the repository's deploy/ folder."
    }
}

Write-Host "Installing the patch agent to $InstallRoot"

if (-not (Test-Path -LiteralPath $InstallRoot)) {
    New-Item -Path $InstallRoot -ItemType Directory -Force | Out-Null
}

Copy-Item -LiteralPath $sourceScript -Destination (Join-Path $InstallRoot 'Install-AvdPatch.ps1') -Force
Copy-Item -LiteralPath $sourceModule -Destination $InstallRoot -Recurse -Force

<#
    Lock down the install directory.

    The installer runs as SYSTEM, so anything a standard user can write here is
    code they can get executed with full privileges. On a multi-session host
    that means every signed-in user. Inheritance is removed and Users are given
    read and execute only.
#>
$acl = Get-Acl -LiteralPath $InstallRoot
$acl.SetAccessRuleProtection($true, $false)
$acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }

$rules = @(
    [System.Security.AccessControl.FileSystemAccessRule]::new('SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    [System.Security.AccessControl.FileSystemAccessRule]::new('Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    [System.Security.AccessControl.FileSystemAccessRule]::new('Users', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
)
foreach ($rule in $rules) { $acl.AddAccessRule($rule) }

if ($PSCmdlet.ShouldProcess($InstallRoot, 'Apply restrictive ACL')) {
    Set-Acl -LiteralPath $InstallRoot -AclObject $acl
    Write-Host 'Applied restrictive ACL (SYSTEM/Administrators full, Users read-only).'
}

foreach ($dir in @('C:\ProgramData\AvdPatch\cache', 'C:\ProgramData\AvdPatch\logs')) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

# --------------------------------------------------------------------------
# Register the task
# --------------------------------------------------------------------------

$scriptArgs = @(
    '-ExecutionPolicy Bypass'
    '-NoProfile'
    '-NonInteractive'
    "-File `"$InstallRoot\Install-AvdPatch.ps1`""
    "-StorageAccount $StorageAccount"
    "-Container $Container"
    "-MaxJitterSeconds $MaxJitterSeconds"
)
if ($ManagedIdentityClientId) { $scriptArgs += "-ManagedIdentityClientId $ManagedIdentityClientId" }
if ($Reboot) { $scriptArgs += '-Reboot' }

$arguments = ($scriptArgs -join ' ')
$startBoundary = '{0:yyyy-MM-dd}T{1}:00' -f (Get-Date), $StartTime

# ScheduleByMonthDayOfWeek is the only way to express "second Wednesday"; the
# ScheduledTasks cmdlets do not surface it.
$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Installs Microsoft security updates staged in Azure Storage. Part of avd-patch-management.</Description>
    <URI>$taskPath$TaskName</URI>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByMonthDayOfWeek>
        <Weeks>
          <Week>$WeekOfMonth</Week>
        </Weeks>
        <DaysOfWeek>
          <$DayOfWeek />
        </DaysOfWeek>
        <Months>
          <January /><February /><March /><April /><May /><June />
          <July /><August /><September /><October /><November /><December />
        </Months>
      </ScheduleByMonthDayOfWeek>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT4H</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT30M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe</Command>
      <Arguments>$arguments</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = Join-Path $env:TEMP 'avd-patch-task.xml'
# Task Scheduler expects UTF-16 for imported XML.
[System.IO.File]::WriteAllText($xmlPath, $taskXml, [System.Text.Encoding]::Unicode)

try {
    $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host 'Existing task found; replacing it.'
        if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister existing task')) {
            Unregister-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -Confirm:$false
        }
    }

    if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {
        Register-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -Xml $taskXml -Force | Out-Null

        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $taskPath
        $info = $task | Get-ScheduledTaskInfo

        Write-Host ''
        Write-Host 'Registered successfully.' -ForegroundColor Green
        Write-Host "  Task:      $taskPath$TaskName"
        Write-Host "  Schedule:  $WeekOfMonth $DayOfWeek of every month at $StartTime local"
        Write-Host "  Next run:  $($info.NextRunTime)"
        Write-Host "  Runs as:   SYSTEM"
        Write-Host "  Storage:   $StorageAccount/$Container"
        Write-Host "  Reboot:    $Reboot"
        Write-Host ''
        Write-Host 'Test it now without waiting for the schedule:'
        Write-Host "  Start-ScheduledTask -TaskName '$TaskName' -TaskPath '$taskPath'"
        Write-Host '  Get-Content C:\ProgramData\AvdPatch\logs\*.log -Tail 40'
    }
}
finally {
    Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
}
