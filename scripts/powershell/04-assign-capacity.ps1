#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$CapacityId,
    [string]$ConfigPath = "$PSScriptRoot\..\..\config.local.json",
    [string]$StatePath = "$PSScriptRoot\..\..\.demo-state\workspace.json",
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 180
)
$ErrorActionPreference = 'Stop'
if ($CapacityId -eq [guid]::Empty) { throw 'CapacityId cannot be empty.' }
Import-Module "$PSScriptRoot\FabricDemo.psm1" -Force
$config = Read-DemoConfig -Path $ConfigPath
$receipt = Read-DemoReceipt -Path $StatePath -Config $config
$context = Get-FabricContext -Config $config
$capacities = @(Get-FabricCollection -Context $context -Path '/capacities')
$target = @($capacities | Where-Object { $_.id -eq $CapacityId.ToString() })
if ($target.Count -ne 1 -or $target[0].state -ne 'Active') {
    throw 'Target must be a visible Active capacity. No assignment was submitted.'
}
$path = "/workspaces/$($receipt.workspaceId)"
$current = (Invoke-FabricRequest -Context $context -Method GET -Path $path).Data
if ($current.capacityId -eq $CapacityId.ToString() -and $current.capacityAssignmentProgress -eq 'Completed') {
    Write-Host 'Assignment already complete; no POST needed.'
    return
}
if ($current.capacityId -and $current.capacityId -ne $CapacityId.ToString()) {
    throw 'Demo script refuses to migrate an already assigned workspace. Create a separate demo workspace instead.'
}
$null = Invoke-FabricRequest -Context $context -Method POST -Path "$path/assignToCapacity" `
    -Body @{ capacityId = $CapacityId.ToString() } -ExpectedStatus 202
Write-Host 'Accepted is not completed; polling workspace metadata.'
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Seconds 3
    $workspace = (Invoke-FabricRequest -Context $context -Method GET -Path $path).Data
    if ($workspace.capacityAssignmentProgress -eq 'Failed') { throw 'Capacity assignment failed.' }
    if ($workspace.capacityId -eq $CapacityId.ToString() -and $workspace.capacityAssignmentProgress -eq 'Completed') {
        Write-Host "Verified assignment to $($target[0].displayName) ($CapacityId)."
        return
    }
} while ([DateTimeOffset]::UtcNow -lt $deadline)
throw 'Assignment not confirmed within timeout. Inspect workspace before retrying; the request may still complete.'
