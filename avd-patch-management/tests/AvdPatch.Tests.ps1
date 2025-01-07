#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Unit tests for AvdPatch.

    Everything here runs offline. The catalog parser is tested against a saved
    fixture rather than the live site, so CI does not break when Microsoft has
    an outage - and, more usefully, a fixture that stops matching the live site
    is a signal worth acting on. Test-CatalogParserAgainstLive.ps1 covers that
    separately and is not part of the default run.
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '../src/AvdPatch/AvdPatch.psd1'
    Import-Module $script:ModulePath -Force

    $script:FixturePath = Join-Path $PSScriptRoot 'fixtures/catalog-search-results.html'
    $script:FixtureHtml = Get-Content -LiteralPath $script:FixturePath -Raw

    function New-TestOs {
        param(
            [int]$Build = 22631,
            [int]$Ubr = 4780,
            [string]$DisplayVersion = '23H2',
            [string]$Architecture = 'x64'
        )
        [pscustomobject]@{
            ComputerName   = 'TESTHOST'
            Caption        = 'Windows 11 Enterprise multi-session'
            EditionId      = 'ServerRdsh'
            BuildNumber    = $Build
            Ubr            = $Ubr
            FullBuild      = "$Build.$Ubr"
            DisplayVersion = $DisplayVersion
            Architecture   = $Architecture
            IsMultiSession = $true
        }
    }

    function New-TestManifest {
        @'
{
  "cycle": "2026-09",
  "updates": [
    { "name":"win11-23h2","kbId":"KB5065432","buildNumber":22631,"displayVersion":"23H2",
      "architecture":"x64","targetUbr":4890,"blobPath":"2026-09/a.msu","sha256":"aa","sizeBytes":100 },
    { "name":"win11-22h2","kbId":"KB5065111","buildNumber":22621,"displayVersion":"22H2",
      "architecture":"x64","targetUbr":4880,"blobPath":"2026-09/b.msu","sha256":"bb","sizeBytes":100 }
  ]
}
'@ | ConvertFrom-Json
    }
}

Describe 'Get-PatchTuesday' {

    It 'returns a Tuesday for every month of a year' {
        foreach ($month in 1..12) {
            (Get-PatchTuesday -Year 2026 -Month $month).DayOfWeek | Should -Be 'Tuesday'
        }
    }

    It 'returns the second Tuesday, so always between the 8th and the 14th' {
        foreach ($month in 1..12) {
            $day = (Get-PatchTuesday -Year 2026 -Month $month).Day
            $day | Should -BeGreaterOrEqual 8
            $day | Should -BeLessOrEqual 14
        }
    }

    It 'handles a month starting on a Tuesday' {
        # 2026-09-01 is a Tuesday, so Patch Tuesday is the 8th, not the 1st.
        Get-PatchTuesday -Year 2026 -Month 9 | Should -Be ([datetime]'2026-09-08')
    }

    It 'handles a month starting on a Wednesday' {
        Get-PatchTuesday -Year 2026 -Month 7 | Should -Be ([datetime]'2026-07-14')
    }

    It 'is not affected by the current culture' {
        $original = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            # de-DE treats Monday as the first day of the week; the result must not move.
            [System.Threading.Thread]::CurrentThread.CurrentCulture = 'de-DE'
            Get-PatchTuesday -Year 2026 -Month 9 | Should -Be ([datetime]'2026-09-08')
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
        }
    }
}

Describe 'Get-PatchCycleTag' {

    It 'returns the current month on Patch Tuesday itself' {
        Get-PatchCycleTag -Date ([datetime]'2026-09-08') | Should -Be '2026-09'
    }

    It 'returns the previous month the day before Patch Tuesday' {
        # This month's updates have not shipped yet.
        Get-PatchCycleTag -Date ([datetime]'2026-09-07') | Should -Be '2026-08'
    }

    It 'still returns the previous cycle early in the following month' {
        Get-PatchCycleTag -Date ([datetime]'2026-10-02') | Should -Be '2026-09'
    }

    It 'rolls the year over correctly in early January' {
        Get-PatchCycleTag -Date ([datetime]'2026-01-05') | Should -Be '2025-12'
    }
}

Describe 'ConvertFrom-MsCatalogHtml' {

    It 'parses every result row in the fixture' {
        @(ConvertFrom-MsCatalogHtml -Html $script:FixtureHtml).Count | Should -Be 5
    }

    It 'extracts the KB id from the title' {
        $updates = ConvertFrom-MsCatalogHtml -Html $script:FixtureHtml
        $updates[0].KbId | Should -Be 'KB5065432'
    }

    It 'extracts the update GUID from the row id' {
        $updates = ConvertFrom-MsCatalogHtml -Html $script:FixtureHtml
        $updates[0].UpdateId | Should -Be 'a1b2c3d4-1111-2222-3333-444455556666'
    }

    It 'extracts the exact byte count, not the rounded display size' {
        $updates = ConvertFrom-MsCatalogHtml -Html $script:FixtureHtml
        $updates[0].SizeBytes | Should -Be 778389504
    }

    It 'keeps the display size free of the hidden byte count' {
        $updates = ConvertFrom-MsCatalogHtml -Html $script:FixtureHtml
        $updates[0].SizeText | Should -Be '742.3 MB'
    }

    It 'parses dates with the invariant culture' {
        # The catalog serves US-format dates whatever the client locale is.
        $original = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = 'en-GB'
            $updates = ConvertFrom-MsCatalogHtml -Html $script:FixtureHtml
            $updates[0].LastUpdated | Should -Be ([datetime]'2026-09-09')
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
        }
    }

    It 'returns an empty set rather than throwing when there are no results' {
        $result = @(ConvertFrom-MsCatalogHtml -Html '<html>ctl00_catalogBody_noResultText</html>')
        $result.Count | Should -Be 0
    }

    It 'returns an empty set for empty input' {
        @(ConvertFrom-MsCatalogHtml -Html '').Count | Should -Be 0
    }
}

Describe 'Select-BestCatalogUpdate' {

    BeforeEach {
        $script:Updates = ConvertFrom-MsCatalogHtml -Html $script:FixtureHtml
    }

    It 'selects the current x64 cumulative update' {
        $best = Select-BestCatalogUpdate -Update $script:Updates `
            -TitleMustMatch 'Cumulative Update for Windows 11' `
            -Architecture 'x64' -Classification 'Security Updates'

        $best.KbId | Should -Be 'KB5065432'
        $best.Title | Should -Match 'x64-based'
    }

    It 'never selects the arm64 build when x64 was asked for' {
        $best = Select-BestCatalogUpdate -Update $script:Updates `
            -TitleMustMatch 'Cumulative Update for Windows 11' -Architecture 'x64'
        $best.Title | Should -Not -Match 'arm64'
    }

    It 'excludes Dynamic Updates, which are for setup media not running hosts' {
        $best = Select-BestCatalogUpdate -Update $script:Updates `
            -TitleMustMatch 'Windows 11' -Architecture 'x64'
        $best.Title | Should -Not -Match 'Dynamic Update'
    }

    It 'excludes .NET Framework rollups' {
        $best = Select-BestCatalogUpdate -Update $script:Updates `
            -TitleMustMatch 'Cumulative Update for Windows 11' -Architecture 'x64'
        $best.Title | Should -Not -Match 'Framework'
    }

    It 'prefers the newest release when several months are returned' {
        $best = Select-BestCatalogUpdate -Update $script:Updates `
            -TitleMustMatch 'Cumulative Update for Windows 11' -Architecture 'x64'
        # September, not the August rollup also present in the fixture.
        $best.KbId | Should -Be 'KB5065432'
    }

    It 'returns null when nothing matches rather than guessing' {
        $best = Select-BestCatalogUpdate -Update $script:Updates -TitleMustMatch 'Windows Server 2022'
        $best | Should -BeNullOrEmpty
    }
}

Describe 'Select-ManifestEntry' {

    It 'matches the entry for the running build' {
        $entry = Select-ManifestEntry -Manifest (New-TestManifest) -OsIdentity (New-TestOs -Build 22631)
        $entry.kbId | Should -Be 'KB5065432'
    }

    It 'distinguishes Windows 11 22H2 from 23H2' {
        # 22621 and 22631 are serviced by different KBs; picking the wrong one
        # ships an update that will simply be rejected.
        $entry = Select-ManifestEntry -Manifest (New-TestManifest) -OsIdentity (New-TestOs -Build 22621 -DisplayVersion '22H2')
        $entry.kbId | Should -Be 'KB5065111'
    }

    It 'returns nothing for an architecture the manifest does not cover' {
        $entry = Select-ManifestEntry -Manifest (New-TestManifest) -OsIdentity (New-TestOs -Architecture 'arm64')
        $entry | Should -BeNullOrEmpty
    }

    It 'returns nothing for an unmanaged build' {
        $entry = Select-ManifestEntry -Manifest (New-TestManifest) -OsIdentity (New-TestOs -Build 20348)
        $entry | Should -BeNullOrEmpty
    }
}

Describe 'Test-UpdateApplicable' {

    It 'installs when the host UBR is below the target' {
        $entry = Select-ManifestEntry -Manifest (New-TestManifest) -OsIdentity (New-TestOs -Ubr 4780)
        $decision = Test-UpdateApplicable -OsIdentity (New-TestOs -Ubr 4780) -ManifestEntry $entry

        $decision.Applicable | Should -BeTrue
        $decision.Action | Should -Be 'Install'
    }

    It 'skips when the host is exactly at the target UBR' {
        $entry = Select-ManifestEntry -Manifest (New-TestManifest) -OsIdentity (New-TestOs -Ubr 4890)
        $decision = Test-UpdateApplicable -OsIdentity (New-TestOs -Ubr 4890) -ManifestEntry $entry

        $decision.Applicable | Should -BeFalse
        $decision.Action | Should -Be 'AlreadyCurrent'
    }

    It 'skips when the host is ahead of the target UBR' {
        $entry = Select-ManifestEntry -Manifest (New-TestManifest) -OsIdentity (New-TestOs -Ubr 5000)
        $decision = Test-UpdateApplicable -OsIdentity (New-TestOs -Ubr 5000) -ManifestEntry $entry

        $decision.Applicable | Should -BeFalse
    }

    It 'reports NoUpdateAvailable rather than failing when nothing matches' {
        $decision = Test-UpdateApplicable -OsIdentity (New-TestOs) -ManifestEntry $null

        $decision.Applicable | Should -BeFalse
        $decision.Action | Should -Be 'NoUpdateAvailable'
    }

    It 'always explains itself so the report is auditable' {
        $decision = Test-UpdateApplicable -OsIdentity (New-TestOs) -ManifestEntry $null
        $decision.Reason | Should -Not -BeNullOrEmpty
    }

    It 'overrides the applicability checks when Force is used' {
        $entry = Select-ManifestEntry -Manifest (New-TestManifest) -OsIdentity (New-TestOs -Ubr 9999)
        $decision = Test-UpdateApplicable -OsIdentity (New-TestOs -Ubr 9999) -ManifestEntry $entry -Force

        $decision.Applicable | Should -BeTrue
    }
}

Describe 'Get-DismExitCodeInfo' {

    It 'treats 0 as success with no reboot' {
        $info = Get-DismExitCodeInfo -ExitCode 0
        $info.Success | Should -BeTrue
        $info.RebootRequired | Should -BeFalse
    }

    It 'treats 3010 as SUCCESS, not failure' {
        # The single most important mapping here: 3010 is the normal outcome for
        # a cumulative update and must never page anyone.
        $info = Get-DismExitCodeInfo -ExitCode 3010
        $info.Success | Should -BeTrue
        $info.RebootRequired | Should -BeTrue
        $info.Status | Should -Be 'SuccessRebootRequired'
    }

    It 'treats "not applicable" as success' {
        (Get-DismExitCodeInfo -ExitCode -2146498530).Success | Should -BeTrue
    }

    It 'treats an installer-busy code as a retryable failure' {
        $info = Get-DismExitCodeInfo -ExitCode 1618
        $info.Success | Should -BeFalse
        $info.Status | Should -Be 'InstallerBusy'
    }

    It 'fails closed on an unmapped exit code' {
        $info = Get-DismExitCodeInfo -ExitCode 999999
        $info.Success | Should -BeFalse
        $info.Status | Should -Be 'Failed'
        $info.Message | Should -Match 'dism.log'
    }
}

Describe 'Get-BlobUri' {

    It 'builds a container-scoped URL' {
        Get-BlobUri -StorageAccount 'stfoo' -Container 'patches' |
            Should -Be 'https://stfoo.blob.core.windows.net/patches'
    }

    It 'keeps path separators unescaped while escaping the segments' {
        Get-BlobUri -StorageAccount 'stfoo' -Container 'patches' -BlobPath '2026-09/win11.msu' |
            Should -Be 'https://stfoo.blob.core.windows.net/patches/2026-09/win11.msu'
    }

    It 'appends a SAS token, tolerating a leading question mark' {
        Get-BlobUri -StorageAccount 'stfoo' -Container 'p' -BlobPath 'a.msu' -SasToken '?sv=x&sig=y' |
            Should -Be 'https://stfoo.blob.core.windows.net/p/a.msu?sv=x&sig=y'
    }

    It 'supports sovereign cloud endpoints' {
        Get-BlobUri -StorageAccount 'stfoo' -Container 'p' -EndpointSuffix 'core.usgovcloudapi.net' |
            Should -Be 'https://stfoo.blob.core.usgovcloudapi.net/p'
    }
}

Describe 'Get-CleanCellText' {

    It 'strips tags and collapses whitespace' {
        Get-CleanCellText -Html "<a href='#'>  Hello   <b>World</b>  </a>" | Should -Be 'Hello World'
    }

    It 'decodes HTML entities' {
        Get-CleanCellText -Html '<td>Windows&nbsp;11 &amp; Server</td>' | Should -Match 'Windows 11 & Server'
    }
}
