#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-DemoConfig {
    param([Parameter(Mandatory)][string]$Path, [switch]$DelegatedUser)
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $requiredIds = if ($DelegatedUser) { @('tenantId') } else { @('tenantId', 'clientId') }
    foreach ($key in $requiredIds) {
        $id = [guid]::Empty
        if (-not [guid]::TryParse([string]$config[$key], [ref]$id) -or $id -eq [guid]::Empty) {
            throw "Set $key to a nonempty GUID in the local configuration."
        }
    }
    if ($config.fabricApiBaseUrl -cne 'https://api.fabric.microsoft.com/v1') {
        throw 'Only the documented public-cloud Fabric endpoint is allowed.'
    }
    $allowed = @('tenantId', 'clientId', 'subscriptionId', 'resourceGroup',
        'fabricApiBaseUrl', 'capacity1Id', 'capacity2Id', 'workspaceAdminUPN', 'workspaceAdminObjectId')
    foreach ($key in $config.Keys) {
        if ($key -notin $allowed) { throw "Unsupported configuration key: $key. Never store credentials here." }
    }
    return $config
}

function Invoke-DemoAz {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI failed. Resolve its error; no identity fallback is attempted.' }
    if ($output) { return ($output -join "`n" | ConvertFrom-Json -AsHashtable) }
}

function Get-DemoAccessToken {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [ValidateSet('https://api.fabric.microsoft.com', 'https://api.kusto.windows.net',
            'https://analysis.windows.net/powerbi/api')]
        [string]$Resource = 'https://api.fabric.microsoft.com',
        [switch]$DelegatedUser
    )
    $token = Invoke-DemoAz -Arguments @('account', 'get-access-token',
        '--tenant', $Config.tenantId, '--resource', $Resource)
    if (-not $token.accessToken) { throw 'Azure CLI returned no access token.' }
    # Claims are an identity guard/display, not a substitute for service-side token validation.
    $part = $token.accessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $part = $part.PadRight($part.Length + ((4 - $part.Length % 4) % 4), '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) |
        ConvertFrom-Json -AsHashtable
    $appId = if ($claims['appid']) { $claims['appid'] } else { $claims['azp'] }
    if ($claims.tid -ne $Config.tenantId) { throw 'Wrong tenant. Authenticate in the configured tenant.' }
    if ($DelegatedUser -and -not $claims['scp']) {
        throw 'DelegatedUser requires a signed-in user token, not an automation identity.'
    }
    if (-not $DelegatedUser -and ($appId -ne $Config.clientId -or $claims['scp'])) {
        throw 'Wrong tenant/client or delegated user token. Sign in as the configured automation identity.'
    }
    if ([long]$claims.exp -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 30) {
        throw 'Token is expired or about to expire. Authenticate again.'
    }
    Write-Host "Identity: app=$appId object=$($claims.oid) tenant=$($claims.tid)"
    Write-Host "Requested resource: $Resource; token audience: $($claims.aud)"
    return @{ Token = $token.accessToken; Claims = $claims }
}

function Get-FabricContext {
    param([Parameter(Mandatory)][hashtable]$Config)
    $context = Get-DemoAccessToken -Config $Config
    $context.BaseUrl = $Config.fabricApiBaseUrl
    return $context
}

function Invoke-FabricRequest {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Body,
        [int[]]$ExpectedStatus = @(200),
        [int[]]$AllowStatus = @()
    )
    if (-not $Path.StartsWith('/') -or $Path.StartsWith('//') -or $Path.Contains('..')) {
        throw 'A relative Fabric API path is required.'
    }
    $uri = $Context.BaseUrl + $Path
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        Write-Host "$Method $uri"
        $request = @{
            Uri = $uri; Method = $Method
            Headers = @{ Authorization = "Bearer $($Context.Token)" }
            SkipHttpErrorCheck = $true; MaximumRedirection = 0; TimeoutSec = 60
        }
        if ($PSBoundParameters.ContainsKey('Body')) {
            $request.Body = $Body | ConvertTo-Json -Depth 10 -Compress
            $request.ContentType = 'application/json'
        }
        $response = Invoke-WebRequest @request
        $status = [int]$response.StatusCode
        Write-Host "HTTP $status"
        if ($Method -eq 'GET' -and $status -in @(429, 503) -and $attempt -lt 3) {
            $delay = 5
            $retryAfter = @($response.Headers['Retry-After'])[0]
            if ($retryAfter) {
                if (-not [int]::TryParse([string]$retryAfter, [ref]$delay)) {
                    $retryDate = [DateTimeOffset]::Parse([string]$retryAfter)
                    $delay = [int][Math]::Ceiling(($retryDate - [DateTimeOffset]::UtcNow).TotalSeconds)
                }
            }
            if ($delay -gt 120) { throw "Retry-After=$delay seconds exceeds this demo's wait budget. Retry later." }
            Start-Sleep -Seconds ([Math]::Max(1, $delay))
            continue
        }
        if ($status -notin ($ExpectedStatus + $AllowStatus)) {
            $detail = if ($response.Content) { [string]$response.Content } else { '(empty response)' }
            throw "Fabric request failed: HTTP $status; $detail. Writes are never automatically retried."
        }
        $data = if ($response.Content) {
            $response.Content | ConvertFrom-Json -AsHashtable
        } else { $null }
        return @{ Status = $status; Data = $data; Headers = $response.Headers }
    }
}

function Get-FabricCollection {
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$Path)
    $items = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new()
    $next = $Path
    for ($page = 0; $page -lt 1000; $page++) {
        $response = Invoke-FabricRequest -Context $Context -Method GET -Path $next
        if (-not $response.Data.ContainsKey('value')) { throw 'Invalid paged response: missing value.' }
        foreach ($item in $response.Data.value) { $items.Add($item) }
        $token = [string]$response.Data['continuationToken']
        if (-not $token) { return $items.ToArray() }
        if (-not $seen.Add($token)) { throw 'Repeated continuation token; refusing an endless pagination loop.' }
        # Reconstruct the path instead of sending a bearer token to a continuation URI.
        $separator = if ($Path.Contains('?')) { '&' } else { '?' }
        $next = $Path + $separator + 'continuationToken=' + [uri]::EscapeDataString($token)
    }
    throw 'Pagination exceeded the safety limit; inventory is incomplete.'
}

function Read-DemoReceipt {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Config)
    $receipt = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($receipt.tenantId -ne $Config.tenantId -or $receipt.clientId -ne $Config.clientId) {
        throw 'Receipt tenant/client does not match local configuration.'
    }
    if ($receipt.status -ne 'Created' -or -not $receipt.workspaceId -or -not $receipt.marker) {
        throw 'Receipt does not identify a live workspace created by this demo.'
    }
    return $receipt
}

function Save-DemoReceipt {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Receipt)
    $fullPath = [IO.Path]::GetFullPath($Path)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
    $Receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $fullPath -Encoding utf8
}

Export-ModuleMember -Function Read-DemoConfig, Invoke-DemoAz, Get-DemoAccessToken, Get-FabricContext,
    Invoke-FabricRequest, Get-FabricCollection, Read-DemoReceipt, Save-DemoReceipt
