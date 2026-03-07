[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $DataCollectionRuleId
)

$ErrorActionPreference = 'Stop'
$vms = Get-AzVM -ResourceGroupName $ResourceGroupName |
    Where-Object { $_.Tags.workload -eq 'azure-virtual-desktop' }

foreach ($vm in $vms) {
    if (-not $PSCmdlet.ShouldProcess($vm.Name, 'Install Azure Monitor Agent and associate DCR')) {
        continue
    }

    Set-AzVMExtension `
        -ResourceGroupName $ResourceGroupName `
        -VMName $vm.Name `
        -Location $vm.Location `
        -Name 'AzureMonitorWindowsAgent' `
        -Publisher 'Microsoft.Azure.Monitor' `
        -ExtensionType 'AzureMonitorWindowsAgent' `
        -TypeHandlerVersion '1.0' `
        -EnableAutomaticUpgrade $true

    New-AzDataCollectionRuleAssociation `
        -TargetResourceId $vm.Id `
        -AssociationName "dcra-$($vm.Name)" `
        -RuleId $DataCollectionRuleId
}
