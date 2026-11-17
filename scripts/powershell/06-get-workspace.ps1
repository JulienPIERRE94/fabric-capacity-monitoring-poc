#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\..\config.local.json",
    [string]$StatePath = "$PSScriptRoot\..\..\.demo-state\workspace.json"
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\FabricDemo.psm1" -Force
$config = Read-DemoConfig -Path $ConfigPath
$receipt = Read-DemoReceipt -Path $StatePath -Config $config
$context = Get-FabricContext -Config $config
$workspace = (Invoke-FabricRequest -Context $context -Method GET -Path "/workspaces/$($receipt.workspaceId)").Data
$capacities = @(Get-FabricCollection -Context $context -Path '/capacities')
$capacity = @($capacities | Where-Object { $_.id -eq $workspace.capacityId })
[pscustomobject]@{
    WorkspaceId = $workspace.id; WorkspaceName = $workspace.displayName
    CapacityId = $workspace.capacityId
    CapacityName = if ($capacity.Count -eq 1) { $capacity[0].displayName } else { '(not accessible or unassigned)' }
    AssignmentProgress = $workspace.capacityAssignmentProgress
}
Write-Host 'Workspace role assignments:'
Get-FabricCollection -Context $context -Path "/workspaces/$($receipt.workspaceId)/roleAssignments" |
    ForEach-Object { [pscustomobject]$_ }
