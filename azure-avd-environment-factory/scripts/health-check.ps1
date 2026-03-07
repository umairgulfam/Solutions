[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $HostPoolName
)

$ErrorActionPreference = 'Stop'
$hosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName

$result = foreach ($host in $hosts) {
    [pscustomobject]@{
        Name              = $host.Name
        Status            = $host.Status
        Sessions          = $host.Session
        AllowNewSession   = $host.AllowNewSession
        AgentVersion      = $host.AgentVersion
        LastHeartBeat     = $host.LastHeartBeat
        UpdateState       = $host.UpdateState
    }
}

$result | Format-Table -AutoSize
if ($result.Status -contains 'Unavailable') {
    Write-Error 'One or more session hosts are unavailable.'
}

