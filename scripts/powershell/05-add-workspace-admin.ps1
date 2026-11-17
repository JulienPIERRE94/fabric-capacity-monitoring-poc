#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\..\config.local.json",
    [string]$StatePath = "$PSScriptRoot\..\..\.demo-state\workspace.json",
    [guid]$PrincipalObjectId = [guid]::Empty,
    [ValidateSet('User', 'Group')][string]$PrincipalType = 'User',
    [ValidateSet('Admin', 'Member', 'Contributor', 'Viewer')][string]$Role = 'Admin'
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\FabricDemo.psm1" -Force
$config = Read-DemoConfig -Path $ConfigPath
if ($PrincipalObjectId -eq [guid]::Empty -and $PrincipalType -eq 'User') {
    $PrincipalObjectId = [guid]$config.workspaceAdminObjectId
}
if ($PrincipalObjectId -eq [guid]::Empty) { throw 'Supply the Entra principal OBJECT ID, not an app/client ID or UPN.' }
$receipt = Read-DemoReceipt -Path $StatePath -Config $config
$context = Get-FabricContext -Config $config
$path = "/workspaces/$($receipt.workspaceId)/roleAssignments"
$existing = @(Get-FabricCollection -Context $context -Path $path |
    Where-Object { $_.principal.id -eq $PrincipalObjectId.ToString() })
if ($existing.Count -gt 0) {
    if ($existing.Count -eq 1 -and $existing[0].role -eq $Role -and $existing[0].principal.type -eq $PrincipalType) {
        Write-Host 'Requested role assignment already exists.'
        return
    }
    throw 'Principal already has a different assignment. No automatic role change/escalation is performed.'
}
Write-Host "Adding $PrincipalType $PrincipalObjectId as $Role (UPN label: $($config.workspaceAdminUPN))."
$null = Invoke-FabricRequest -Context $context -Method POST -Path $path -ExpectedStatus 201 `
    -Body @{ principal = @{ id = $PrincipalObjectId.ToString(); type = $PrincipalType }; role = $Role }
$confirmed = @(Get-FabricCollection -Context $context -Path $path | Where-Object {
    $_.principal.id -eq $PrincipalObjectId.ToString() -and $_.role -eq $Role -and $_.principal.type -eq $PrincipalType
})
if ($confirmed.Count -ne 1) { throw 'POST succeeded but role was not observed. Check propagation before retrying.' }
Write-Host 'Role assignment verified.'
