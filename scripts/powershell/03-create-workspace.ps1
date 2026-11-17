#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\..\config.local.json",
    [ValidatePattern('^Fabric-API-Demo-[A-Za-z0-9-]+$')][string]$WorkspaceName = 'Fabric-API-Demo-01',
    [guid]$CapacityId = [guid]::Empty,
    [string]$StatePath = "$PSScriptRoot\..\..\.demo-state\workspace.json"
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\FabricDemo.psm1" -Force
$config = Read-DemoConfig -Path $ConfigPath
if (Test-Path -LiteralPath $StatePath) {
    throw 'Receipt already exists. Inspect it; use a different StatePath for a new workspace. No existing workspace is adopted.'
}
$context = Get-FabricContext -Config $config
if ($CapacityId -ne [guid]::Empty) {
    $capacities = @(Get-FabricCollection -Context $context -Path '/capacities')
    $target = @($capacities | Where-Object { $_.id -eq $CapacityId.ToString() })
    if ($target.Count -ne 1 -or $target[0].state -ne 'Active') {
        throw 'Selected capacity is not uniquely visible and Active.'
    }
}
$marker = "Fabric API demo ownership: $([guid]::NewGuid())"
$receipt = @{
    tenantId = $config.tenantId; clientId = $config.clientId; displayName = $WorkspaceName
    marker = $marker; status = 'Pending'; workspaceId = ''
}
# Reserve the receipt before the non-idempotent POST. A Pending receipt requires manual investigation.
Save-DemoReceipt -Path $StatePath -Receipt $receipt
$body = @{ displayName = $WorkspaceName; description = $marker }
if ($CapacityId -ne [guid]::Empty) { $body.capacityId = $CapacityId.ToString() }
$response = Invoke-FabricRequest -Context $context -Method POST -Path '/workspaces' -Body $body -ExpectedStatus 201
if (-not $response.Data.id) { throw 'Create response has no ID. Investigate Pending receipt; do not repeat creation blindly.' }
$receipt.workspaceId = $response.Data.id
$receipt.status = 'Created'
Write-Host "Created workspace ID: $($receipt.workspaceId). Retain this ID if writing the receipt fails."
Save-DemoReceipt -Path $StatePath -Receipt $receipt
$roles = @(Get-FabricCollection -Context $context -Path "/workspaces/$($receipt.workspaceId)/roleAssignments")
$owner = @($roles | Where-Object { $_.principal.id -eq $context.Claims.oid -and $_.role -eq 'Admin' })
if ($owner.Count -eq 0) { throw 'Creator Admin role was not observed. Investigate before continuing; workspace exists.' }
[pscustomobject]$response.Data
