#Requires -Version 5.1

<#
.SYNOPSIS
    Script 1 of 2. Downloads the current month's security updates from the
    Microsoft Update Catalog and stages them in an Azure Storage account.

.DESCRIPTION
    Runs once per cycle, on or shortly after Patch Tuesday, from a single
    trusted location - an Azure Automation runbook, a container job or a
    management server. Session hosts never talk to the catalog themselves.

    For each target defined in the config it:
      1. Searches the catalog for the cycle's update
      2. Selects the single correct result (right product, architecture,
         classification; not a Dynamic Update or .NET rollup)
      3. Downloads the .msu and records its SHA256
      4. Uploads it to blob storage
      5. Writes a manifest describing what session hosts should install

    The manifest is the contract between the two scripts. It is written last and
    atomically: if any download fails, the previous cycle's manifest stays in
    place and session hosts keep doing something sane rather than reading a
    half-written file.

.PARAMETER ConfigPath
    Path to patch-config.json. Defaults to ../config/patch-config.json.

.PARAMETER StorageAccount
    Storage account name. Overrides the config file.

.PARAMETER Container
    Blob container for patches. Overrides the config file.

.PARAMETER Cycle
    Patch cycle as yyyy-MM. Defaults to the current cycle. Use this to
    re-run a previous month.

.PARAMETER WorkingDirectory
    Where updates are downloaded before upload. Needs room for the largest
    update, typically 2 GB or more.

.PARAMETER SkipUpload
    Download and verify only. Useful for testing catalog parsing without
    touching storage.

.PARAMETER Force
    Re-download and re-upload even when the blob already exists.

.EXAMPLE
    ./Invoke-PatchDownload.ps1 -Verbose

.EXAMPLE
    ./Invoke-PatchDownload.ps1 -Cycle 2026-08 -Force
    Re-stages last month's updates.

.NOTES
    Requires the Storage Blob Data Contributor role on the target container for
    whichever identity runs it.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config/patch-config.json'),
    [string]$StorageAccount,
    [string]$Container,
    [ValidatePattern('^\d{4}-\d{2}$')]
    [string]$Cycle,
    [string]$WorkingDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) 'avd-patch-download'),
    [string]$ManagedIdentityClientId,
    [switch]$SkipUpload,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../src/AvdPatch/AvdPatch.psd1') -Force

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

if (-not $StorageAccount) { $StorageAccount = $config.storage.accountName }
if (-not $Container) { $Container = $config.storage.patchContainer }
if (-not $Cycle) { $Cycle = Get-PatchCycleTag }
if (-not $ManagedIdentityClientId -and $config.storage.PSObject.Properties.Name -contains 'managedIdentityClientId') {
    $ManagedIdentityClientId = $config.storage.managedIdentityClientId
}

if (-not $StorageAccount -and -not $SkipUpload) {
    throw 'No storage account specified. Set storage.accountName in the config or pass -StorageAccount.'
}

$logDirectory = if ($config.logging.PSObject.Properties.Name -contains 'downloaderLogPath' -and $config.logging.downloaderLogPath) {
    $config.logging.downloaderLogPath
}
else {
    Join-Path $WorkingDirectory 'logs'
}
$logFile = Join-Path $logDirectory ("patch-download-{0}-{1:yyyyMMdd-HHmmss}.log" -f $Cycle, (Get-Date))
Initialize-PatchLog -Path $logFile | Out-Null

Write-PatchLog "=== AVD patch download starting for cycle $Cycle ==="
Write-PatchLog "Patch Tuesday for this cycle: $((Get-PatchTuesday -Year ([int]$Cycle.Split('-')[0]) -Month ([int]$Cycle.Split('-')[1])).ToString('yyyy-MM-dd'))"
Write-PatchLog "Storage: $StorageAccount/$Container  SkipUpload=$SkipUpload  Force=$Force"

if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
    New-Item -Path $WorkingDirectory -ItemType Directory -Force | Out-Null
}

# --------------------------------------------------------------------------
# Process each target
# --------------------------------------------------------------------------

$manifestEntries = [System.Collections.Generic.List[pscustomobject]]::new()
$failures = [System.Collections.Generic.List[string]]::new()

foreach ($target in $config.targets) {

    if ($target.PSObject.Properties.Name -contains 'enabled' -and -not $target.enabled) {
        Write-PatchLog "Skipping disabled target '$($target.name)'." -Level Information
        continue
    }

    Write-PatchLog "--- Target: $($target.name) ---"

    try {
        # The catalog titles updates with the cycle, e.g. "2026-09 Cumulative
        # Update for Windows 11 Version 23H2". Building the query from the cycle
        # is what makes this run unattended every month.
        $query = $target.searchQueryTemplate -replace '\{cycle\}', $Cycle
        Write-PatchLog "Catalog query: $query"

        # @() so a zero-result search does not unroll to $null and break .Count
        $results = @(Find-MsCatalogUpdate -Query $query)
        Write-PatchLog "Catalog returned $($results.Count) result(s)."

        if ($results.Count -eq 0) {
            throw "No catalog results for '$query'. If this is Patch Tuesday, the update may not have published yet."
        }

        $selectParams = @{
            Update       = $results
            Architecture = $target.architecture
        }
        if ($target.PSObject.Properties.Name -contains 'titleMustMatch' -and $target.titleMustMatch) {
            $selectParams['TitleMustMatch'] = $target.titleMustMatch
        }
        if ($target.PSObject.Properties.Name -contains 'titleMustNotMatch' -and $target.titleMustNotMatch) {
            $selectParams['TitleMustNotMatch'] = $target.titleMustNotMatch
        }
        if ($target.PSObject.Properties.Name -contains 'classification' -and $target.classification) {
            $selectParams['Classification'] = $target.classification
        }

        $update = Select-BestCatalogUpdate @selectParams

        if (-not $update) {
            throw "None of the $($results.Count) catalog results matched the filters for '$($target.name)'. Review titleMustMatch/architecture/classification in the config."
        }

        Write-PatchLog "Selected: $($update.Title)"
        Write-PatchLog "  UpdateId=$($update.UpdateId)  KB=$($update.KbId)  Size=$($update.SizeText)"

        # ---- resolve the CDN URL ----
        $urls = Get-MsCatalogDownloadUrl -UpdateId $update.UpdateId -FileExtension 'msu'
        $downloadUrl = $urls[0]
        if ($urls.Count -gt 1) {
            Write-PatchLog "Catalog returned $($urls.Count) files; using the first: $downloadUrl" -Level Warning
        }

        $fileName = ($downloadUrl -split '/')[-1] -replace '\?.*$', ''
        $localPath = Join-Path $WorkingDirectory $fileName
        $blobPath = "$Cycle/$fileName"

        # ---- skip work already done ----
        $blobPresent = $false
        if (-not $SkipUpload -and -not $Force) {
            $blobPresent = Test-BlobExists -StorageAccount $StorageAccount -Container $Container -BlobPath $blobPath -ClientId $ManagedIdentityClientId
        }

        if ($blobPresent) {
            Write-PatchLog "Blob $blobPath already exists; skipping download. Use -Force to replace."

            # Still need the hash for the manifest. Prefer a cached local copy.
            if (Test-Path -LiteralPath $localPath) {
                $sha256 = Get-FileSha256 -Path $localPath
                $sizeBytes = (Get-Item -LiteralPath $localPath).Length
            }
            else {
                Write-PatchLog 'No local copy available to hash; downloading to compute the manifest hash.' -Level Warning
                Save-CatalogFile -Url $downloadUrl -Destination $localPath
                $sha256 = Get-FileSha256 -Path $localPath
                $sizeBytes = (Get-Item -LiteralPath $localPath).Length
            }
        }
        else {
            Write-PatchLog "Downloading $fileName from the Microsoft CDN..."
            Save-CatalogFile -Url $downloadUrl -Destination $localPath

            $sizeBytes = (Get-Item -LiteralPath $localPath).Length
            $sha256 = Get-FileSha256 -Path $localPath
            Write-PatchLog "Downloaded $([math]::Round($sizeBytes / 1MB, 1)) MB  SHA256=$sha256"

            # The catalog's advertised size is a useful sanity check against a
            # truncated transfer. A mismatch is a warning rather than a failure
            # because the catalog occasionally rounds.
            if ($update.SizeBytes -gt 0) {
                $delta = [math]::Abs($sizeBytes - $update.SizeBytes)
                if ($delta -gt ($update.SizeBytes * 0.02)) {
                    Write-PatchLog "Downloaded size $sizeBytes differs from the catalog's stated $($update.SizeBytes) by more than 2%." -Level Warning
                }
            }

            if (-not $SkipUpload) {
                Write-PatchLog "Uploading to $Container/$blobPath ..."
                if ($PSCmdlet.ShouldProcess("$Container/$blobPath", 'Upload update')) {
                    Set-BlobFromFile -StorageAccount $StorageAccount -Container $Container -BlobPath $blobPath `
                        -Path $localPath -ClientId $ManagedIdentityClientId `
                        -Metadata @{ kb = $update.KbId; cycle = $Cycle; sha256 = $sha256 } -Confirm:$false
                    Write-PatchLog 'Upload complete.'
                }
            }
        }

        $manifestEntries.Add([pscustomobject]@{
                name           = $target.name
                kbId           = $update.KbId
                title          = $update.Title
                updateId       = $update.UpdateId
                classification = $update.Classification
                buildNumber    = [int]$target.buildNumber
                displayVersion = $target.displayVersion
                architecture   = $target.architecture
                targetUbr      = [int]$target.targetUbr
                fileName       = $fileName
                blobPath       = $blobPath
                sizeBytes      = [int64]$sizeBytes
                sha256         = $sha256
                releasedOn     = if ($update.LastUpdated) { $update.LastUpdated.ToString('yyyy-MM-dd') } else { $null }
                sourceUrl      = $downloadUrl
            })

        Write-PatchLog "Target '$($target.name)' staged successfully."
    }
    catch {
        $message = "Target '$($target.name)' failed: $($_.Exception.Message)"
        Write-PatchLog $message -Level Error
        $failures.Add($message)
    }
}

# --------------------------------------------------------------------------
# Manifest
# --------------------------------------------------------------------------

if ($manifestEntries.Count -eq 0) {
    Write-PatchLog 'No updates were staged. Leaving the existing manifest untouched.' -Level Error
    throw "Patch download produced no usable updates for cycle $Cycle. $($failures.Count) target(s) failed."
}

# targetUbr in the config is what makes the installer's "am I already patched?"
# check work. Flag it rather than silently shipping a manifest that always
# reinstalls.
foreach ($entry in $manifestEntries) {
    if ($entry.targetUbr -le 0) {
        Write-PatchLog "Target '$($entry.name)' has no targetUbr set. Session hosts will fall back to a KB-presence check, which is slower and less reliable. Set targetUbr from the KB article." -Level Warning
    }
}

$manifest = [pscustomobject]@{
    schemaVersion = 1
    cycle         = $Cycle
    generatedAt   = (Get-Date).ToUniversalTime().ToString('o')
    generatedBy   = $env:COMPUTERNAME
    storage       = [pscustomobject]@{ accountName = $StorageAccount; container = $Container }
    updateCount   = $manifestEntries.Count
    failureCount  = $failures.Count
    failures      = @($failures)
    updates       = @($manifestEntries)
}

$manifestJson = $manifest | ConvertTo-Json -Depth 6
$localManifest = Join-Path $WorkingDirectory "manifest-$Cycle.json"
$manifestJson | Set-Content -LiteralPath $localManifest -Encoding UTF8
Write-PatchLog "Manifest written locally to $localManifest"

if (-not $SkipUpload) {
    if ($PSCmdlet.ShouldProcess('manifest', 'Upload manifest')) {
        # Cycle-specific copy first, then the pointer session hosts actually
        # read. Writing 'latest' last means hosts never see a manifest whose
        # blobs are not uploaded yet.
        Set-BlobFromText -StorageAccount $StorageAccount -Container $Container `
            -BlobPath "manifests/manifest-$Cycle.json" -Content $manifestJson `
            -ClientId $ManagedIdentityClientId -Confirm:$false

        Set-BlobFromText -StorageAccount $StorageAccount -Container $Container `
            -BlobPath 'manifests/latest.json' -Content $manifestJson `
            -ClientId $ManagedIdentityClientId -Confirm:$false

        Write-PatchLog 'Manifest published to manifests/latest.json'
    }
}

Write-PatchLog "=== Complete. $($manifestEntries.Count) update(s) staged, $($failures.Count) failure(s). ==="

if ($failures.Count -gt 0) {
    Write-PatchLog 'Some targets failed. Session hosts for those targets will not be patched this cycle.' -Level Warning
    exit 2
}

exit 0
