[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [string] $OutputPath = './avd-validation.json'
)

$ErrorActionPreference = 'Stop'
$checks = [System.Collections.Generic.List[object]]::new()
$pools = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName

foreach ($pool in $pools) {
    $hosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $pool.Name
    $available = @($hosts | Where-Object Status -eq 'Available').Count
    $checks.Add([pscustomobject]@{
        HostPool      = $pool.Name
        Type          = $pool.HostPoolType
        TotalHosts    = @($hosts).Count
        Available     = $available
        Healthy       = @($hosts).Count -gt 0 -and $available -eq @($hosts).Count
    })
}

$checks | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding UTF8
$checks | Format-Table -AutoSize
if ($checks.Healthy -contains $false) { exit 1 }

