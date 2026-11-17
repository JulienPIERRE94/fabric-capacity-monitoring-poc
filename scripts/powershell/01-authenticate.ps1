#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\..\config.local.json",
    [ValidateSet('Certificate', 'ManagedIdentity', 'ExistingSession')][string]$Mode = 'Certificate',
    [string]$CertificatePath,
    [switch]$SystemAssigned
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\FabricDemo.psm1" -Force
$config = Read-DemoConfig -Path $ConfigPath
switch ($Mode) {
    Certificate {
        if (-not $CertificatePath -or -not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
            throw 'Supply -CertificatePath to a protected PEM (private key + certificate) outside the repository.'
        }
        $resolvedCertificate = (Resolve-Path -LiteralPath $CertificatePath).Path
        $root = [IO.Path]::GetFullPath("$PSScriptRoot\..\..") + [IO.Path]::DirectorySeparatorChar
        if ($resolvedCertificate.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The private-key PEM must be outside the repository.'
        }
        $null = Invoke-DemoAz -Arguments @('login', '--service-principal', '--username',
            $config.clientId, '--tenant', $config.tenantId, '--certificate',
            $resolvedCertificate, '--allow-no-subscriptions')
    }
    ManagedIdentity {
        $arguments = @('login', '--identity', '--allow-no-subscriptions')
        if (-not $SystemAssigned) { $arguments += @('--client-id', $config.clientId) }
        $null = Invoke-DemoAz -Arguments $arguments
    }
    ExistingSession {
        Write-Host 'Using existing workload-authenticated Azure CLI session; delegated users are rejected.'
    }
}
$context = Get-FabricContext -Config $config
$null = Invoke-FabricRequest -Context $context -Method GET -Path '/capacities'
Write-Host 'Token acquisition and first Fabric request succeeded. No token is printed or saved by these scripts.'
