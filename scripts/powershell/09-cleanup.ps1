#requires -Version 7.2
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ConfirmWorkspaceName,
    [string]$ConfigPath = "$PSScriptRoot\..\..\config.local.json",
    [string]$StatePath = "$PSScriptRoot\..\..\.demo-state\workspace.json"
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\FabricDemo.psm1" -Force
$config = Read-DemoConfig -Path $ConfigPath
$receipt = Read-DemoReceipt -Path $StatePath -Config $config
$context = Get-FabricContext -Config $config
$path = "/workspaces/$($receipt.workspaceId)"
$workspace = (Invoke-FabricRequest -Context $context -Method GET -Path $path).Data
if ($ConfirmWorkspaceName -cne $receipt.displayName -or $workspace.displayName -cne $receipt.displayName -or
    $workspace.description -cne $receipt.marker -or $workspace.displayName -notlike 'Fabric-API-Demo-*') {
    throw 'Name/ownership verification failed. Nothing was deleted.'
}
if ($PSCmdlet.ShouldProcess("$($workspace.displayName) [$($workspace.id)]", 'Delete workspace AND ALL its items')) {
    $null = Invoke-FabricRequest -Context $context -Method DELETE -Path $path
    $check = Invoke-FabricRequest -Context $context -Method GET -Path $path -AllowStatus 404
    if ($check.Status -ne 404) { throw 'Deletion not yet verified. Receipt retained as Created; inspect workspace.' }
    $receipt.status = 'Deleted'
    Save-DemoReceipt -Path $StatePath -Receipt $receipt
    Write-Host 'Deletion verified by HTTP 404. Receipt retained for audit. Capacities and monitoring resources were NOT deleted.'
}
