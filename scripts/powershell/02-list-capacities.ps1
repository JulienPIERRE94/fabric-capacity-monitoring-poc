#requires -Version 7.2
[CmdletBinding()]
param([string]$ConfigPath = "$PSScriptRoot\..\..\config.local.json")
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\FabricDemo.psm1" -Force
$config = Read-DemoConfig -Path $ConfigPath
$context = Get-FabricContext -Config $config
$capacities = @(Get-FabricCollection -Context $context -Path '/capacities')
if ($capacities.Count -eq 0) { throw 'No accessible capacities. Ask the capacity admin to grant Contributor access.' }
$capacities | ForEach-Object { [pscustomobject]$_ }
