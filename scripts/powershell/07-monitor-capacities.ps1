#requires -Version 7.2
[CmdletBinding()]
param([string]$ConfigPath = "$PSScriptRoot\..\..\config.local.json")
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\FabricDemo.psm1" -Force
$config = Read-DemoConfig -Path $ConfigPath
$context = Get-FabricContext -Config $config
$capacities = @(Get-FabricCollection -Context $context -Path '/capacities')
$expected = @($config.capacity1Id, $config.capacity2Id | Where-Object { $_ })
if ($expected.Count -notin @(0, 2)) { throw 'Configure both capacity IDs or neither.' }
if ($expected.Count -eq 0) {
    if ($capacities.Count -ne 2) { throw 'Expected two accessible demo capacities. Set capacity1Id/capacity2Id explicitly.' }
    $expected = @($capacities | ForEach-Object { $_.id })
}
if ($expected[0] -eq $expected[1]) { throw 'The two demo capacity IDs must differ.' }
foreach ($id in $expected) {
    $selected = @($capacities | Where-Object { $_.id -eq $id })
    if ($selected.Count -ne 1) { throw "Expected capacity $id is not accessible. Inventory is incomplete." }
}
$workspaces = @(Get-FabricCollection -Context $context -Path '/workspaces')
foreach ($capacity in $capacities | Where-Object { $_.id -in $expected }) {
    [pscustomobject]@{
        CapacityId = $capacity.id; CapacityName = $capacity.displayName
        SKU = $capacity.sku; State = $capacity.state; Region = $capacity.region
        AccessibleWorkspaceIds = @($workspaces | Where-Object { $_.capacityId -eq $capacity.id } |
            ForEach-Object { $_.id })
        ConsumptionSource = 'Capacity Metrics app / configured capacity events; NOT this inventory API'
    }
}
Write-Host 'Accessible workspaces are NOT all workspaces on the capacity.'
Write-Host 'CU/utilization/throttling: Not directly available through a public REST API in this inventory path.'
Write-Host 'Use MONITORING.md and monitoring\capacity-operations.kql. Missing consumption is not zero consumption.'
