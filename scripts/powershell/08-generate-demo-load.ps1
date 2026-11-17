#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Write-Host 'MANUAL WORKLOAD: this helper does not submit a Fabric job or claim that load was generated.'
Write-Host '1. In a disposable, assigned demo workspace, create a Spark notebook. No Lakehouse is needed.'
Write-Host '2. Select Spark SQL for a cell and paste the query below. Run once; at most twice.'
Get-Content -LiteralPath "$PSScriptRoot\..\..\workloads\demo-load.sql"
Write-Host '3. Record UTC time, capacity/workspace/item IDs and run status. Stop the Spark session afterwards.'
Write-Host '4. Repeat on the second capacity using a SECOND workspace, not a cross-region migration.'
Write-Host '5. Allow 10-15 minutes for Metrics usage; check operation events separately. Visibility is not guaranteed by row count.'
Write-Host 'Optional interactive contrast: run a few read-only queries against your own tiny semantic model/report.'
Write-Host 'Do not induce throttling. Use existing history or clearly labelled pre-recorded evidence.'
