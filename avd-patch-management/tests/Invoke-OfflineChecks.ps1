#Requires -Version 5.1

<#
.SYNOPSIS
    Runs the core logic checks without Pester.

.DESCRIPTION
    AvdPatch.Tests.ps1 is the full suite and needs Pester 5. This script covers
    the same critical assertions using nothing but PowerShell, so it runs on a
    locked-down management server or an air-gapped build agent where installing
    from the PowerShell Gallery is not an option.

    Use it as a smoke test before deploying a change to the module.

.EXAMPLE
    ./Invoke-OfflineChecks.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '../src/AvdPatch/AvdPatch.psd1') -Force

$script:Passed = 0
$script:Failed = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()

function Assert-That {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        # AllowNull because "returns null when nothing matches" is itself a
        # behaviour worth asserting, and Mandatory alone would reject it.
        [Parameter(Mandatory, Position = 1)][AllowNull()]$Actual,
        [Parameter(Mandatory, Position = 2)][AllowNull()]$Expected
    )

    $actualText = if ($null -eq $Actual) { '<null>' } else { [string]$Actual }
    $expectedText = if ($null -eq $Expected) { '<null>' } else { [string]$Expected }

    if ($actualText -eq $expectedText) {
        $script:Passed++
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    }
    else {
        $script:Failed++
        $message = "{0}`n          expected: {1}`n          actual:   {2}" -f $Name, $expectedText, $actualText
        $script:Failures.Add($message)
        Write-Host ("  FAIL  {0}" -f $message) -ForegroundColor Red
    }
}

function New-TestOs {
    param([int]$Build = 22631, [int]$Ubr = 4780, [string]$DisplayVersion = '23H2', [string]$Architecture = 'x64')
    [pscustomobject]@{
        ComputerName = 'TESTHOST'; Caption = 'Windows 11 Enterprise multi-session'
        EditionId = 'ServerRdsh'; BuildNumber = $Build; Ubr = $Ubr
        FullBuild = "$Build.$Ubr"; DisplayVersion = $DisplayVersion
        Architecture = $Architecture; IsMultiSession = $true
    }
}

$manifest = @'
{ "cycle":"2026-09","updates":[
 {"name":"win11-23h2","kbId":"KB5065432","buildNumber":22631,"displayVersion":"23H2","architecture":"x64","targetUbr":4890,"blobPath":"2026-09/a.msu","sha256":"aa","sizeBytes":100},
 {"name":"win11-22h2","kbId":"KB5065111","buildNumber":22621,"displayVersion":"22H2","architecture":"x64","targetUbr":4880,"blobPath":"2026-09/b.msu","sha256":"bb","sizeBytes":100}
]}
'@ | ConvertFrom-Json

$fixture = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/catalog-search-results.html') -Raw

Write-Host "`nPatch Tuesday" -ForegroundColor Cyan
Assert-That 'September 2026 is the 8th' (Get-PatchTuesday -Year 2026 -Month 9).ToString('yyyy-MM-dd') '2026-09-08'
Assert-That 'July 2026 is the 14th' (Get-PatchTuesday -Year 2026 -Month 7).ToString('yyyy-MM-dd') '2026-07-14'
Assert-That 'February 2027 is the 9th' (Get-PatchTuesday -Year 2027 -Month 2).ToString('yyyy-MM-dd') '2027-02-09'
$allTuesdays = (1..12 | ForEach-Object { (Get-PatchTuesday -Year 2026 -Month $_).DayOfWeek } | Select-Object -Unique)
Assert-That 'every month lands on a Tuesday' $allTuesdays 'Tuesday'
$inRange = (1..12 | ForEach-Object { $d = (Get-PatchTuesday -Year 2026 -Month $_).Day; $d -ge 8 -and $d -le 14 } | Select-Object -Unique)
Assert-That 'every month falls between the 8th and 14th' $inRange 'True'

Write-Host "`nCycle tag" -ForegroundColor Cyan
Assert-That 'on Patch Tuesday'          (Get-PatchCycleTag -Date ([datetime]'2026-09-08')) '2026-09'
Assert-That 'day before Patch Tuesday'  (Get-PatchCycleTag -Date ([datetime]'2026-09-07')) '2026-08'
Assert-That 'catch-up run next month'   (Get-PatchCycleTag -Date ([datetime]'2026-10-02')) '2026-09'
Assert-That 'year rollover in January'  (Get-PatchCycleTag -Date ([datetime]'2026-01-05')) '2025-12'

Write-Host "`nCatalog parser" -ForegroundColor Cyan
$updates = ConvertFrom-MsCatalogHtml -Html $fixture
Assert-That 'parses all rows'            $updates.Count 5
Assert-That 'extracts KB id'             $updates[0].KbId 'KB5065432'
Assert-That 'extracts update GUID'       $updates[0].UpdateId 'a1b2c3d4-1111-2222-3333-444455556666'
Assert-That 'extracts exact byte count'  $updates[0].SizeBytes 778389504
Assert-That 'display size excludes bytes' $updates[0].SizeText '742.3 MB'
Assert-That 'parses the release date'    $updates[0].LastUpdated.ToString('yyyy-MM-dd') '2026-09-09'
Assert-That 'no-results page is empty'   @(ConvertFrom-MsCatalogHtml -Html '<html>ctl00_catalogBody_noResultText</html>').Count 0
Assert-That 'empty input is empty'       @(ConvertFrom-MsCatalogHtml -Html '').Count 0

Write-Host "`nUpdate selection" -ForegroundColor Cyan
$best = Select-BestCatalogUpdate -Update $updates -TitleMustMatch 'Cumulative Update for Windows 11' -Architecture 'x64' -Classification 'Security Updates'
Assert-That 'selects the current x64 CU' $best.KbId 'KB5065432'
Assert-That 'rejects arm64'              ($best.Title -match 'arm64') 'False'
Assert-That 'rejects Dynamic Update'     ($best.Title -match 'Dynamic') 'False'
Assert-That 'rejects .NET rollup'        ($best.Title -match 'Framework') 'False'
Assert-That 'no match returns null'      (Select-BestCatalogUpdate -Update $updates -TitleMustMatch 'Windows Server 2022') $null

Write-Host "`nManifest matching" -ForegroundColor Cyan
Assert-That '23H2 host matches its KB'   (Select-ManifestEntry -Manifest $manifest -OsIdentity (New-TestOs -Build 22631)).kbId 'KB5065432'
Assert-That '22H2 host matches its KB'   (Select-ManifestEntry -Manifest $manifest -OsIdentity (New-TestOs -Build 22621 -DisplayVersion '22H2')).kbId 'KB5065111'
Assert-That 'arm64 host matches nothing' (Select-ManifestEntry -Manifest $manifest -OsIdentity (New-TestOs -Architecture 'arm64')) $null
Assert-That 'Server build matches nothing' (Select-ManifestEntry -Manifest $manifest -OsIdentity (New-TestOs -Build 20348)) $null

Write-Host "`nApplicability" -ForegroundColor Cyan
$behind = New-TestOs -Ubr 4780
$current = New-TestOs -Ubr 4890
$ahead = New-TestOs -Ubr 5000
Assert-That 'behind target installs'     (Test-UpdateApplicable -OsIdentity $behind  -ManifestEntry (Select-ManifestEntry -Manifest $manifest -OsIdentity $behind)).Action  'Install'
Assert-That 'at target skips'            (Test-UpdateApplicable -OsIdentity $current -ManifestEntry (Select-ManifestEntry -Manifest $manifest -OsIdentity $current)).Action 'AlreadyCurrent'
Assert-That 'ahead of target skips'      (Test-UpdateApplicable -OsIdentity $ahead   -ManifestEntry (Select-ManifestEntry -Manifest $manifest -OsIdentity $ahead)).Action   'AlreadyCurrent'
Assert-That 'no entry is not an error'   (Test-UpdateApplicable -OsIdentity $behind -ManifestEntry $null).Action 'NoUpdateAvailable'
Assert-That 'Force overrides the check'  (Test-UpdateApplicable -OsIdentity $ahead -ManifestEntry (Select-ManifestEntry -Manifest $manifest -OsIdentity $ahead) -Force).Applicable 'True'
Assert-That 'always gives a reason'      ([string]::IsNullOrWhiteSpace((Test-UpdateApplicable -OsIdentity $behind -ManifestEntry $null).Reason)) 'False'

Write-Host "`nDISM exit codes" -ForegroundColor Cyan
Assert-That '0 is success'               (Get-DismExitCodeInfo -ExitCode 0).Success 'True'
Assert-That '3010 is SUCCESS not failure' (Get-DismExitCodeInfo -ExitCode 3010).Success 'True'
Assert-That '3010 requires a reboot'     (Get-DismExitCodeInfo -ExitCode 3010).RebootRequired 'True'
Assert-That 'not-applicable is success'  (Get-DismExitCodeInfo -ExitCode -2146498530).Success 'True'
Assert-That 'installer busy is failure'  (Get-DismExitCodeInfo -ExitCode 1618).Success 'False'
Assert-That 'unknown code fails closed'  (Get-DismExitCodeInfo -ExitCode 999999).Status 'Failed'

Write-Host "`nBlob URI construction" -ForegroundColor Cyan
Assert-That 'container URL'  (Get-BlobUri -StorageAccount 'stfoo' -Container 'patches') 'https://stfoo.blob.core.windows.net/patches'
Assert-That 'blob path kept unescaped' (Get-BlobUri -StorageAccount 'stfoo' -Container 'patches' -BlobPath '2026-09/win11.msu') 'https://stfoo.blob.core.windows.net/patches/2026-09/win11.msu'
Assert-That 'SAS appended'   (Get-BlobUri -StorageAccount 'stfoo' -Container 'p' -BlobPath 'a.msu' -SasToken '?sv=x') 'https://stfoo.blob.core.windows.net/p/a.msu?sv=x'
Assert-That 'sovereign cloud' (Get-BlobUri -StorageAccount 'stfoo' -Container 'p' -EndpointSuffix 'core.usgovcloudapi.net') 'https://stfoo.blob.core.usgovcloudapi.net/p'

Write-Host "`nHTML helpers" -ForegroundColor Cyan
Assert-That 'strips tags'      (Get-CleanCellText -Html "<a href='#'>  Hello   <b>World</b>  </a>") 'Hello World'
Assert-That 'decodes entities' (Get-CleanCellText -Html '<td>Windows&nbsp;11 &amp; Server</td>') 'Windows 11 & Server'

Write-Host ''
Write-Host ('-' * 60)
if ($script:Failed -eq 0) {
    Write-Host ("ALL CHECKS PASSED  ({0} assertions)" -f $script:Passed) -ForegroundColor Green
    exit 0
}

Write-Host ("{0} PASSED, {1} FAILED" -f $script:Passed, $script:Failed) -ForegroundColor Red
$script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
