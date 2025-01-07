#Requires -Version 5.1

<#
    Azure Blob Storage access over the REST API.

    Deliberately no dependency on the Az PowerShell modules. Script 2 runs on
    every session host, and requiring Az.Storage there would mean installing and
    version-managing a large module fleet-wide, in an image that gets rebuilt
    monthly. Everything here works with Windows PowerShell 5.1 as shipped.

    Authentication is by managed identity wherever possible. SAS is supported as
    a fallback for machines that are not Azure VMs, but managed identity should
    be preferred: a SAS token in a config file is a credential sitting on every
    session host, and rotating it means touching every machine.
#>

$script:StorageApiVersion = '2021-12-02'
$script:ImdsEndpoint = 'http://169.254.169.254/metadata/identity/oauth2/token'
$script:TokenCache = @{}

function Get-AzureImdsToken {
    <#
    .SYNOPSIS
        Gets an access token from the Instance Metadata Service.

    .PARAMETER Resource
        The resource the token is for. Blob storage is https://storage.azure.com/.

    .PARAMETER ClientId
        Client ID of a user-assigned managed identity. Omit for system-assigned.

    .NOTES
        Tokens are cached in-process until five minutes before expiry, so a run
        that touches many blobs does not hammer IMDS.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Resource = 'https://storage.azure.com/',
        [string]$ClientId,
        [int]$MaxRetries = 4
    )

    $cacheKey = '{0}|{1}' -f $Resource, $ClientId
    $cached = $script:TokenCache[$cacheKey]
    if ($cached -and $cached.ExpiresOn -gt (Get-Date).AddMinutes(5)) {
        Write-Verbose 'Using cached IMDS token.'
        return $cached.Token
    }

    $uri = '{0}?api-version=2018-02-01&resource={1}' -f $script:ImdsEndpoint, [uri]::EscapeDataString($Resource)
    if ($ClientId) {
        $uri += '&client_id={0}' -f [uri]::EscapeDataString($ClientId)
    }

    $attempt = 0
    $lastError = $null

    while ($attempt -le $MaxRetries) {
        try {
            # IMDS must never go through a proxy. -NoProxy does not exist in 5.1,
            # so the environment is cleared for the duration of the call instead.
            $savedProxy = $env:HTTP_PROXY, $env:HTTPS_PROXY
            $env:HTTP_PROXY = $null
            $env:HTTPS_PROXY = $null

            try {
                $response = Invoke-RestMethod -Uri $uri `
                    -Headers @{ Metadata = 'true' } `
                    -Method GET `
                    -TimeoutSec 30 `
                    -UseBasicParsing `
                    -ErrorAction Stop
            }
            finally {
                $env:HTTP_PROXY = $savedProxy[0]
                $env:HTTPS_PROXY = $savedProxy[1]
            }

            $expiresOn = [DateTimeOffset]::FromUnixTimeSeconds([int64]$response.expires_on).LocalDateTime
            $script:TokenCache[$cacheKey] = @{ Token = $response.access_token; ExpiresOn = $expiresOn }

            Write-Verbose "Acquired IMDS token for $Resource (expires $expiresOn)."
            return $response.access_token
        }
        catch {
            $lastError = $_
            $attempt++
            if ($attempt -gt $MaxRetries) { break }
            Start-Sleep -Seconds ([math]::Pow(2, $attempt))
        }
    }

    throw "Could not acquire a managed identity token for '$Resource'. Confirm the VM has an identity assigned and that IMDS (169.254.169.254) is reachable. Last error: $($lastError.Exception.Message)"
}

function New-BlobRequestHeader {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$AccessToken,
        [hashtable]$Additional = @{}
    )

    $headers = @{
        'x-ms-version' = $script:StorageApiVersion
        'x-ms-date'    = [DateTime]::UtcNow.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($AccessToken) {
        $headers['Authorization'] = "Bearer $AccessToken"
    }
    foreach ($key in $Additional.Keys) {
        $headers[$key] = $Additional[$key]
    }
    return $headers
}

function Get-BlobUri {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StorageAccount,
        [Parameter(Mandatory)][string]$Container,
        [string]$BlobPath,
        [string]$SasToken,
        [string]$EndpointSuffix = 'core.windows.net'
    )

    $uri = 'https://{0}.blob.{1}/{2}' -f $StorageAccount, $EndpointSuffix, $Container
    if ($BlobPath) {
        # Each segment is escaped separately so slashes stay as path separators.
        $encoded = ($BlobPath -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $uri += "/$encoded"
    }
    if ($SasToken) {
        $uri += '?' + $SasToken.TrimStart('?')
    }
    return $uri
}

function Get-BlobText {
    <#
    .SYNOPSIS
        Downloads a blob and returns it as a string. Used for the manifest.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StorageAccount,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$BlobPath,
        [string]$SasToken,
        [string]$ClientId,
        [string]$EndpointSuffix = 'core.windows.net'
    )

    $uri = Get-BlobUri -StorageAccount $StorageAccount -Container $Container -BlobPath $BlobPath -SasToken $SasToken -EndpointSuffix $EndpointSuffix
    $token = if ($SasToken) { $null } else { Get-AzureImdsToken -ClientId $ClientId }
    $headers = New-BlobRequestHeader -AccessToken $token

    Write-Verbose "GET blob $Container/$BlobPath"
    $response = Invoke-WebRequest -Uri $uri -Headers $headers -Method GET -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    return [string]$response.Content
}

function Save-BlobToFile {
    <#
    .SYNOPSIS
        Streams a blob to disk.

    .DESCRIPTION
        Cumulative updates run to several hundred megabytes, so the content is
        streamed rather than buffered in memory. Downloads land on a .part file
        and are moved into place only once complete, so an interrupted run
        cannot leave a truncated .msu that looks valid to the next one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StorageAccount,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$BlobPath,
        [Parameter(Mandatory)][string]$Destination,
        [string]$SasToken,
        [string]$ClientId,
        [string]$EndpointSuffix = 'core.windows.net',
        [int]$TimeoutSec = 1800
    )

    $uri = Get-BlobUri -StorageAccount $StorageAccount -Container $Container -BlobPath $BlobPath -SasToken $SasToken -EndpointSuffix $EndpointSuffix
    $token = if ($SasToken) { $null } else { Get-AzureImdsToken -ClientId $ClientId }
    $headers = New-BlobRequestHeader -AccessToken $token

    $parentDir = Split-Path -Path $Destination -Parent
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
    }

    $partial = "$Destination.part"
    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }

    Write-Verbose "Downloading $Container/$BlobPath to $Destination"

    $previousProgress = $ProgressPreference
    # Invoke-WebRequest's progress bar makes large downloads dramatically slower
    # in Windows PowerShell 5.1.
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $uri -Headers $headers -Method GET -OutFile $partial -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
    }
    finally {
        $ProgressPreference = $previousProgress
    }

    Move-Item -LiteralPath $partial -Destination $Destination -Force
    return $Destination
}

function Set-BlobFromFile {
    <#
    .SYNOPSIS
        Uploads a file to blob storage as a block blob.

    .DESCRIPTION
        Single-shot PUT, which the REST API allows up to 5000 MiB. Cumulative
        updates are comfortably inside that, so block staging is not needed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$StorageAccount,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$BlobPath,
        [Parameter(Mandatory)][string]$Path,
        [string]$SasToken,
        [string]$ClientId,
        [string]$ContentType = 'application/octet-stream',
        [hashtable]$Metadata = @{},
        [string]$EndpointSuffix = 'core.windows.net',
        [int]$TimeoutSec = 3600
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot upload '$Path' because it does not exist."
    }

    $uri = Get-BlobUri -StorageAccount $StorageAccount -Container $Container -BlobPath $BlobPath -SasToken $SasToken -EndpointSuffix $EndpointSuffix
    $token = if ($SasToken) { $null } else { Get-AzureImdsToken -ClientId $ClientId }

    $extra = @{
        'x-ms-blob-type'   = 'BlockBlob'
        'x-ms-blob-content-type' = $ContentType
    }
    foreach ($key in $Metadata.Keys) {
        # Metadata names must be valid C# identifiers; strip anything else.
        $safeName = ($key -replace '[^A-Za-z0-9_]', '')
        $extra["x-ms-meta-$safeName"] = [string]$Metadata[$key]
    }

    $headers = New-BlobRequestHeader -AccessToken $token -Additional $extra

    if (-not $PSCmdlet.ShouldProcess("$Container/$BlobPath", 'Upload blob')) {
        return
    }

    Write-Verbose "PUT blob $Container/$BlobPath"
    Invoke-WebRequest -Uri $uri -Headers $headers -Method PUT -InFile $Path -ContentType $ContentType -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
}

function Set-BlobFromText {
    <#
    .SYNOPSIS
        Uploads a string to blob storage. Used for manifests and reports.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$StorageAccount,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$BlobPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [string]$SasToken,
        [string]$ClientId,
        [string]$ContentType = 'application/json',
        [string]$EndpointSuffix = 'core.windows.net'
    )

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("avdpatch-{0}.tmp" -f ([guid]::NewGuid().ToString('N')))
    try {
        # UTF8 without BOM: a BOM breaks ConvertFrom-Json on the reading end in
        # Windows PowerShell 5.1.
        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($temp, $Content, $encoding)

        if ($PSCmdlet.ShouldProcess("$Container/$BlobPath", 'Upload text blob')) {
            Set-BlobFromFile -StorageAccount $StorageAccount -Container $Container -BlobPath $BlobPath `
                -Path $temp -SasToken $SasToken -ClientId $ClientId -ContentType $ContentType `
                -EndpointSuffix $EndpointSuffix -Confirm:$false
        }
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Test-BlobExists {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$StorageAccount,
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$BlobPath,
        [string]$SasToken,
        [string]$ClientId,
        [string]$EndpointSuffix = 'core.windows.net'
    )

    $uri = Get-BlobUri -StorageAccount $StorageAccount -Container $Container -BlobPath $BlobPath -SasToken $SasToken -EndpointSuffix $EndpointSuffix
    $token = if ($SasToken) { $null } else { Get-AzureImdsToken -ClientId $ClientId }
    $headers = New-BlobRequestHeader -AccessToken $token

    try {
        Invoke-WebRequest -Uri $uri -Headers $headers -Method HEAD -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}
