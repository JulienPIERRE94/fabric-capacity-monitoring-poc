#requires -Version 7.2
[CmdletBinding()]
param([string]$ConfigPath = "$PSScriptRoot\..\..\config.local.json")
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\FabricDemo.psm1" -Force
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Install Azure CLI from Microsoft before continuing. No automatic installation is performed.'
}
$config = Read-DemoConfig -Path $ConfigPath
Write-Host "PowerShell $($PSVersionTable.PSVersion); Azure CLI available."
Write-Host "Configuration valid for tenant $($config.tenantId), client $($config.clientId)."
Write-Host 'No tenant authorization or connectivity has been tested by this prerequisite check.'
Write-Host 'Use a private Azure CLI config directory outside the repository; do not enable shell transcripts.'
