#Requires -Version 5.1

<#
    Microsoft Update Catalog client.

    The catalog has no public API. Everything here is built on the same two
    endpoints the website itself uses:

        Search.aspx          returns an HTML table of matching updates
        DownloadDialog.aspx  takes an update GUID and returns the CDN URL

    That makes this the most fragile part of the solution. Microsoft can change
    the page markup without notice and the parser will break. Two mitigations
    are built in: the parser is regex-based against stable `id` attributes
    rather than layout, and Test-MsCatalogParser gives you a canary you can run
    on a schedule to find out before Patch Tuesday does.
#>

$script:CatalogBaseUri = 'https://www.catalog.update.microsoft.com'
$script:CatalogUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AvdPatchManagement/1.0'

function Get-PatchTuesday {
    <#
    .SYNOPSIS
        Returns the second Tuesday of a given month.

    .DESCRIPTION
        Patch Tuesday is the second Tuesday of each month. This is pure date
        arithmetic with no dependency on culture or the current locale's first
        day of week, which is why it does not use Get-Date -UFormat.

    .PARAMETER Year
        Four digit year. Defaults to the current year.

    .PARAMETER Month
        Month number 1-12. Defaults to the current month.

    .EXAMPLE
        Get-PatchTuesday -Year 2026 -Month 9
        Returns 2026-09-08.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [ValidateRange(1, 9999)]
        [int]$Year = (Get-Date).Year,

        [ValidateRange(1, 12)]
        [int]$Month = (Get-Date).Month
    )

    $firstOfMonth = [datetime]::new($Year, $Month, 1)

    # DayOfWeek is an enum where Sunday = 0 and Tuesday = 2. Walk forward to the
    # first Tuesday, then add a week.
    $offsetToFirstTuesday = ([int][System.DayOfWeek]::Tuesday - [int]$firstOfMonth.DayOfWeek + 7) % 7
    return $firstOfMonth.AddDays($offsetToFirstTuesday + 7)
}

function Get-PatchCycleTag {
    <#
    .SYNOPSIS
        Returns the yyyy-MM tag for the patch cycle a date belongs to.

    .DESCRIPTION
        Updates released on Patch Tuesday are titled with the month they belong
        to, for example "2026-09 Cumulative Update...". A run on the 8th belongs
        to that month's cycle; a catch-up run on the 2nd of the following month
        still belongs to the previous cycle because the new one has not
        happened yet.

    .PARAMETER Date
        The date to classify. Defaults to now.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [datetime]$Date = (Get-Date)
    )

    $thisMonthsPatchTuesday = Get-PatchTuesday -Year $Date.Year -Month $Date.Month

    if ($Date.Date -lt $thisMonthsPatchTuesday.Date) {
        # This month's updates are not out yet, so we are still on last month's.
        $previous = $Date.AddMonths(-1)
        return '{0:yyyy-MM}' -f $previous
    }

    return '{0:yyyy-MM}' -f $Date
}

function ConvertFrom-MsCatalogHtml {
    <#
    .SYNOPSIS
        Parses the Microsoft Update Catalog search results table.

    .DESCRIPTION
        Separated from the HTTP call on purpose so it can be unit tested against
        a saved fixture with no network access. If the catalog markup changes,
        this is the single function to fix.

        Windows PowerShell's Invoke-WebRequest exposes a parsed DOM, but
        PowerShell 7 on Linux does not, and this module has to run in both. So
        it parses with regular expressions anchored on element `id` attributes,
        which have proven far more stable than the surrounding layout.

    .PARAMETER Html
        Raw HTML from Search.aspx.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Html
    )

    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    if ([string]::IsNullOrWhiteSpace($Html)) {
        return $results.ToArray()
    }

    # No results is a legitimate outcome, not an error: a product may simply not
    # have shipped an update this month.
    if ($Html -match 'ctl00_catalogBody_noResultText' -or $Html -match 'We did not find any results') {
        Write-Verbose 'Catalog returned no matching updates.'
        return $results.ToArray()
    }

    # Each result is a <tr id="<guid>_R<n>"> block. Capture up to the next row
    # or the end of the table body.
    $rowPattern = '(?s)<tr[^>]*id="([0-9a-fA-F-]{36})_R\d+"[^>]*>(.*?)</tr>'
    $rowMatches = [regex]::Matches($Html, $rowPattern)

    foreach ($row in $rowMatches) {
        $updateId = $row.Groups[1].Value
        $rowHtml = $row.Groups[2].Value

        $cells = [regex]::Matches($rowHtml, '(?s)<td[^>]*>(.*?)</td>')
        if ($cells.Count -lt 7) {
            Write-Verbose "Skipping row $updateId - expected at least 7 cells, found $($cells.Count)."
            continue
        }

        # Cell layout: 0 blank, 1 title, 2 products, 3 classification,
        # 4 last updated, 5 version, 6 size, 7 download button.
        $title = Get-CleanCellText -Html $cells[1].Groups[1].Value
        $products = Get-CleanCellText -Html $cells[2].Groups[1].Value
        $classification = Get-CleanCellText -Html $cells[3].Groups[1].Value
        $lastUpdatedRaw = Get-CleanCellText -Html $cells[4].Groups[1].Value
        $sizeCellHtml = $cells[6].Groups[1].Value

        # The size cell carries a human string and a hidden exact byte count.
        $sizeBytes = 0
        if ($sizeCellHtml -match '<span[^>]*>\s*([0-9]+)\s*</span>\s*</div>\s*$' -or
            $sizeCellHtml -match 'sizeRaw[^>]*>\s*([0-9]+)') {
            [void][int64]::TryParse($Matches[1], [ref]$sizeBytes)
        }
        # Read the visible span only. Taking the whole cell would append the
        # hidden exact byte count to the human-readable string.
        $sizeText = if ($sizeCellHtml -match '(?s)<span[^>]*_size"[^>]*>(.*?)</span>') {
            Get-CleanCellText -Html $Matches[1]
        }
        else {
            Get-CleanCellText -Html $sizeCellHtml
        }

        $lastUpdated = $null
        $parsed = [datetime]::MinValue
        # The catalog renders US-format dates regardless of the client locale,
        # so parse with InvariantCulture rather than the ambient one.
        if ([datetime]::TryParse(
                $lastUpdatedRaw,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None,
                [ref]$parsed)) {
            $lastUpdated = $parsed
        }

        $kb = $null
        if ($title -match '\b(KB\d{7,})\b') {
            $kb = $Matches[1].ToUpperInvariant()
        }

        $results.Add([pscustomobject]@{
                UpdateId       = $updateId
                Title          = $title
                KbId           = $kb
                Products       = $products
                Classification = $classification
                LastUpdated    = $lastUpdated
                SizeText       = $sizeText
                SizeBytes      = $sizeBytes
            })
    }

    return $results.ToArray()
}

function Get-CleanCellText {
    <#
    .SYNOPSIS
        Strips tags and decodes entities from a table cell's inner HTML.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Html
    )

    $text = [regex]::Replace($Html, '(?s)<[^>]+>', ' ')
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    return ($text -replace '\s+', ' ').Trim()
}

function Find-MsCatalogUpdate {
    <#
    .SYNOPSIS
        Searches the Microsoft Update Catalog.

    .PARAMETER Query
        Search string, exactly as you would type it on the catalog site.
        For example: "2026-09 Cumulative Update Windows 11 Version 23H2 x64".

    .PARAMETER MaxRetries
        Transient failures are common against the catalog. Retries use
        exponential backoff.

    .EXAMPLE
        Find-MsCatalogUpdate -Query '2026-09 Cumulative Update Windows 11 23H2 x64'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Query,

        [ValidateRange(0, 10)]
        [int]$MaxRetries = 3,

        [ValidateRange(5, 600)]
        [int]$TimeoutSec = 60
    )

    $uri = '{0}/Search.aspx?q={1}' -f $script:CatalogBaseUri, [uri]::EscapeDataString($Query)
    Write-Verbose "Searching catalog: $Query"

    $html = Invoke-CatalogRequest -Uri $uri -Method 'GET' -MaxRetries $MaxRetries -TimeoutSec $TimeoutSec

    # @() matters: PowerShell unrolls an empty array to $null on return, so an
    # unwrapped result blows up on .Count under StrictMode - and it does that
    # precisely when the catalog found nothing, which is the case callers most
    # need to handle gracefully.
    $updates = @(ConvertFrom-MsCatalogHtml -Html $html)

    Write-Verbose "Catalog returned $($updates.Count) result(s) for '$Query'."
    return $updates
}

function Get-MsCatalogDownloadUrl {
    <#
    .SYNOPSIS
        Resolves an update GUID to its CDN download URL.

    .DESCRIPTION
        DownloadDialog.aspx returns a fragment of JavaScript containing the real
        file URLs. There is no JSON content type and no documented schema, so
        the URLs are extracted by pattern.

    .PARAMETER UpdateId
        The GUID from Find-MsCatalogUpdate.

    .PARAMETER FileExtension
        Restrict to a file type. Cumulative updates ship as .msu.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$UpdateId,

        [ValidateSet('msu', 'cab', 'exe', 'any')]
        [string]$FileExtension = 'msu',

        [ValidateRange(0, 10)]
        [int]$MaxRetries = 3
    )

    $uri = '{0}/DownloadDialog.aspx' -f $script:CatalogBaseUri

    # The endpoint expects a JSON array in a form field. Build it explicitly
    # rather than with ConvertTo-Json so the shape cannot drift.
    $payload = '[{{"size":0,"languages":"","uidInfo":"{0}","updateID":"{0}"}}]' -f $UpdateId
    $body = @{
        updateIDs               = $payload
        updateIDsBlockedForImport = ''
        wsusApiPresent          = ''
        contentImport           = ''
        sku                     = ''
        serverName              = ''
        ssl                     = ''
        portNumber              = ''
        version                 = ''
    }

    $content = Invoke-CatalogRequest -Uri $uri -Method 'POST' -Body $body -MaxRetries $MaxRetries

    $pattern = if ($FileExtension -eq 'any') {
        "(?<url>https?://[^'\`"\s]+\.(msu|cab|exe|psf))"
    }
    else {
        "(?<url>https?://[^'\`"\s]+\.$FileExtension)"
    }

    $urls = [regex]::Matches($content, $pattern) |
        ForEach-Object { $_.Groups['url'].Value } |
        Select-Object -Unique

    if (-not $urls) {
        throw "No .$FileExtension download URL found for update $UpdateId. The catalog response format may have changed, or this update may not ship that file type."
    }

    return @($urls)
}

function Invoke-CatalogRequest {
    <#
    .SYNOPSIS
        HTTP wrapper with retry and backoff for catalog endpoints.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [hashtable]$Body,
        [int]$MaxRetries = 3,
        [int]$TimeoutSec = 60
    )

    $attempt = 0
    $lastError = $null

    while ($attempt -le $MaxRetries) {
        try {
            $params = @{
                Uri             = $Uri
                Method          = $Method
                TimeoutSec      = $TimeoutSec
                UseBasicParsing = $true
                Headers         = @{ 'User-Agent' = $script:CatalogUserAgent }
                ErrorAction     = 'Stop'
            }
            if ($Method -eq 'POST' -and $Body) {
                $params['Body'] = $Body
            }

            $response = Invoke-WebRequest @params
            return [string]$response.Content
        }
        catch {
            $lastError = $_
            $attempt++
            if ($attempt -gt $MaxRetries) { break }

            $delay = [math]::Pow(2, $attempt)
            Write-Verbose "Catalog request failed (attempt $attempt/$MaxRetries): $($_.Exception.Message). Retrying in ${delay}s."
            Start-Sleep -Seconds $delay
        }
    }

    throw "Catalog request to '$Uri' failed after $MaxRetries retries. Last error: $($lastError.Exception.Message)"
}

function Save-CatalogFile {
    <#
    .SYNOPSIS
        Downloads an update from the Microsoft CDN to disk.

    .DESCRIPTION
        Writes to a .part file and moves it into place only on success, so an
        interrupted download cannot leave a truncated .msu that a later run
        mistakes for a complete one.

    .PARAMETER Url
        CDN URL from Get-MsCatalogDownloadUrl.

    .PARAMETER Destination
        Full local path to write to.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [ValidateRange(60, 7200)][int]$TimeoutSec = 3600,
        [ValidateRange(0, 5)][int]$MaxRetries = 2
    )

    $parent = Split-Path -Path $Destination -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    $partial = "$Destination.part"
    $attempt = 0
    $lastError = $null

    while ($attempt -le $MaxRetries) {
        try {
            if (Test-Path -LiteralPath $partial) {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            }

            $previousProgress = $ProgressPreference
            # The progress bar cripples large downloads in Windows PowerShell 5.1.
            $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing `
                    -TimeoutSec $TimeoutSec -Headers @{ 'User-Agent' = $script:CatalogUserAgent } -ErrorAction Stop
            }
            finally {
                $ProgressPreference = $previousProgress
            }

            if (-not (Test-Path -LiteralPath $partial) -or (Get-Item -LiteralPath $partial).Length -eq 0) {
                throw 'Download produced an empty file.'
            }

            Move-Item -LiteralPath $partial -Destination $Destination -Force
            return $Destination
        }
        catch {
            $lastError = $_
            $attempt++
            if ($attempt -gt $MaxRetries) { break }
            Write-Verbose "Download failed (attempt $attempt): $($_.Exception.Message). Retrying."
            Start-Sleep -Seconds (10 * $attempt)
        }
    }

    throw "Failed to download '$Url' after $MaxRetries retries. Last error: $($lastError.Exception.Message)"
}

function Select-BestCatalogUpdate {
    <#
    .SYNOPSIS
        Picks the single correct update from a set of catalog results.

    .DESCRIPTION
        A catalog search for a cumulative update typically returns the x64, ARM64
        and Server variants together, plus dynamic and .NET updates that are not
        wanted. Filtering wrongly here means shipping the wrong binary to every
        session host, so the include and exclude rules are explicit rather than
        "take the first result".

    .PARAMETER Update
        Results from Find-MsCatalogUpdate.

    .PARAMETER TitleMustMatch
        Regex the title must match, e.g. 'Cumulative Update for Windows 11'.

    .PARAMETER TitleMustNotMatch
        Regex the title must not match. Defaults to excluding Dynamic Update,
        which is for setup media rather than running machines.

    .PARAMETER Architecture
        Architecture token required in the title.

    .PARAMETER Classification
        Restrict to a classification such as 'Security Updates'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Update,

        [string]$TitleMustMatch,
        [string]$TitleMustNotMatch = 'Dynamic Update|Preview|Framework|Out-of-band',
        [string]$Architecture = 'x64',
        [string]$Classification
    )

    $candidates = @($Update)

    if ($TitleMustMatch) {
        $candidates = @($candidates | Where-Object { $_.Title -match $TitleMustMatch })
    }
    if ($TitleMustNotMatch) {
        $candidates = @($candidates | Where-Object { $_.Title -notmatch $TitleMustNotMatch })
    }
    if ($Architecture) {
        # "x64-based Systems" and "arm64" both appear in titles.
        $candidates = @($candidates | Where-Object { $_.Title -match [regex]::Escape($Architecture) })
    }
    if ($Classification) {
        $candidates = @($candidates | Where-Object { $_.Classification -match [regex]::Escape($Classification) })
    }

    if ($candidates.Count -eq 0) {
        return $null
    }

    # Newest wins. Microsoft occasionally re-releases a KB; the later revision
    # is the one to ship.
    return ($candidates | Sort-Object -Property @{Expression = { $_.LastUpdated }; Descending = $true } | Select-Object -First 1)
}
