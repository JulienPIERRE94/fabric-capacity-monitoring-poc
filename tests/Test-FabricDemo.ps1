#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath("$PSScriptRoot\..")
$scripts = Join-Path $root 'scripts\powershell'
$temp = Join-Path ([IO.Path]::GetTempPath()) "fabric-demo-tests-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $temp
$configPath = Join-Path $temp 'config.local.json'
$statePath = Join-Path $temp 'workspace.json'
$pendingPath = Join-Path $temp 'pending.json'
$global:DemoTestQueue = [Collections.Generic.Queue[hashtable]]::new()
$global:DemoTestCalls = [Collections.Generic.List[hashtable]]::new()
$global:DemoTestSleeps = [Collections.Generic.List[int]]::new()
$global:DemoTestClaims = @{
    tid = '11111111-1111-1111-1111-111111111111'
    appid = '22222222-2222-2222-2222-222222222222'
    oid = '33333333-3333-3333-3333-333333333333'
    aud = 'https://api.fabric.microsoft.com'
    exp = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
}
$capacityId = '44444444-4444-4444-4444-444444444444'
$capacity2Id = '55555555-5555-5555-5555-555555555555'
$workspaceId = '66666666-6666-6666-6666-666666666666'
$userId = '77777777-7777-7777-7777-777777777777'
$config = @{
    tenantId = $global:DemoTestClaims.tid; clientId = $global:DemoTestClaims.appid
    fabricApiBaseUrl = 'https://api.fabric.microsoft.com/v1'
    capacity1Id = $capacityId; capacity2Id = $capacity2Id
    workspaceAdminUPN = ''; workspaceAdminObjectId = $userId
}
$config | ConvertTo-Json | Set-Content -LiteralPath $configPath
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $errorFound = $null
    try { $null = & $Action } catch { $errorFound = $_ }
    Assert-True ($null -ne $errorFound) "Expected error matching $Pattern"
    Assert-True ($errorFound.Exception.Message -match $Pattern) "Unexpected error: $($errorFound.Exception.Message)"
}

function Add-Response {
    param([string]$Method, [string]$Path, [int]$Status, [object]$Data, [hashtable]$Headers = @{})
    $global:DemoTestQueue.Enqueue(@{ method=$Method; path=$Path; status=$Status; data=$Data; headers=$Headers })
}

function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    $global:DemoTestQueue.Clear()
    $global:DemoTestCalls.Clear()
    $global:DemoTestSleeps.Clear()
    & $Action
    Assert-True ($global:DemoTestQueue.Count -eq 0) "$Name left unused responses"
    $script:passed++
    Write-Host "PASS: $Name"
}

# All external authentication/HTTP/waiting is replaced in this isolated test process.
function global:az {
    $global:LASTEXITCODE = 0
    if (($args -join ' ') -notmatch 'account get-access-token') {
        throw 'Tests allow only mocked token acquisition, not real CLI login.'
    }
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        ($global:DemoTestClaims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
    @{ accessToken = "test.$payload.not-a-signature" } | ConvertTo-Json -Compress
}

function global:Start-Sleep {
    param([int]$Seconds)
    $global:DemoTestSleeps.Add($Seconds)
}

function global:Invoke-WebRequest {
    param($Uri, $Method, $Headers, $Body, $ContentType, $MaximumRedirection, $TimeoutSec,
        [switch]$SkipHttpErrorCheck)
    if ($global:DemoTestQueue.Count -eq 0) { throw "Unexpected HTTP request: $Method $Uri" }
    $expected = $global:DemoTestQueue.Dequeue()
    if ($Method -ne $expected.method -or $Uri -cne "https://api.fabric.microsoft.com/v1$($expected.path)") {
        throw "Unexpected request: $Method $Uri; expected $($expected.method) $($expected.path)"
    }
    $global:DemoTestCalls.Add(@{ Method=$Method; Uri=$Uri; Body=$Body })
    if ($expected.status -eq 0) { throw 'Simulated uncertain transport failure' }
    [pscustomobject]@{
        StatusCode = $expected.status; Headers = $expected.headers
        Content = if ($null -ne $expected.data) { $expected.data | ConvertTo-Json -Depth 15 -Compress } else { '' }
    }
}

try {
    Test-Case 'All scripts/modules parse; example configuration is valid JSON' {
        foreach ($file in Get-ChildItem -LiteralPath $scripts -File) {
            $tokens = $null; $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            Assert-True ($parseErrors.Count -eq 0) "Syntax error in $($file.Name): $parseErrors"
        }
        $null = Get-Content -LiteralPath (Join-Path $root 'config.example.json') -Raw | ConvertFrom-Json
    }
    Import-Module (Join-Path $scripts 'FabricDemo.psm1') -Force
    $context = Get-FabricContext -Config $config

    Test-Case 'Wrong client and delegated tokens are rejected before HTTP' {
        $global:DemoTestClaims.scp = 'Workspace.ReadWrite.All'
        Assert-Throws { Get-FabricContext -Config $config } 'delegated user token'
        $global:DemoTestClaims.Remove('scp')
        $original = $global:DemoTestClaims.appid
        $global:DemoTestClaims.appid = $userId
        try { Assert-Throws { Get-FabricContext -Config $config } 'Wrong tenant/client' }
        finally { $global:DemoTestClaims.appid = $original }
    }
    Test-Case 'Unexpected endpoint and credential-shaped config keys are rejected' {
        $bad = $config.Clone(); $bad.fabricApiBaseUrl = 'https://example.invalid'
        $bad | ConvertTo-Json | Set-Content -LiteralPath $configPath
        Assert-Throws { Read-DemoConfig -Path $configPath } 'public-cloud Fabric'
        $bad = $config.Clone(); $bad.accessToken = 'not-a-token'
        $bad | ConvertTo-Json | Set-Content -LiteralPath $configPath
        Assert-Throws { Read-DemoConfig -Path $configPath } 'Unsupported configuration key'
        $config | ConvertTo-Json | Set-Content -LiteralPath $configPath
    }
    Test-Case 'Pagination follows encoded token, not arbitrary continuation URI' {
        Add-Response GET '/capacities' 200 @{ value=@(@{id=$capacityId}); continuationToken='a+b/='; continuationUri='https://example.invalid' }
        Add-Response GET '/capacities?continuationToken=a%2Bb%2F%3D' 200 @{ value=@(@{id=$capacity2Id}) }
        $items = @(Get-FabricCollection -Context $context -Path '/capacities')
        Assert-True ($items.Count -eq 2) 'Expected both pages'
    }
    Test-Case 'Repeated continuation tokens fail rather than loop' {
        Add-Response GET '/capacities' 200 @{value=@(); continuationToken='same'}
        Add-Response GET '/capacities?continuationToken=same' 200 @{value=@(); continuationToken='same'}
        Assert-Throws { Get-FabricCollection -Context $context -Path '/capacities' } 'Repeated continuation'
    }
    Test-Case 'GET retry honors Retry-After' {
        Add-Response GET '/capacities' 429 @{errorCode='TooManyRequests'} @{'Retry-After'='7'}
        Add-Response GET '/capacities' 200 @{value=@()}
        $null = Invoke-FabricRequest -Context $context -Method GET -Path '/capacities'
        Assert-True ($global:DemoTestSleeps.Count -eq 1 -and $global:DemoTestSleeps[0] -eq 7) 'Expected seven-second delay'
    }
    Test-Case 'Long Retry-After surfaces failure without retrying too soon' {
        Add-Response GET '/capacities' 429 @{} @{'Retry-After'='600'}
        Assert-Throws { Invoke-FabricRequest -Context $context -Method GET -Path '/capacities' } 'wait budget'
    }
    Test-Case 'POST is not retried and reports HTTP error' {
        Add-Response POST '/workspaces' 429 @{errorCode='TooManyRequests'}
        Assert-Throws { Invoke-FabricRequest -Context $context -Method POST -Path '/workspaces' -Body @{} -ExpectedStatus 201 } 'HTTP 429'
        Assert-True ($global:DemoTestCalls.Count -eq 1) 'POST must not be replayed'
    }
    Test-Case 'Empty/partial two-capacity inventory fails explicitly' {
        Add-Response GET '/capacities' 200 @{value=@(@{id=$capacityId})}
        Assert-Throws { & "$scripts\07-monitor-capacities.ps1" -ConfigPath $configPath } 'not accessible'
    }
    Test-Case 'Two-capacity inventory reports assignments without inventing consumption' {
        Add-Response GET '/capacities' 200 @{value=@(
            @{id=$capacityId; displayName='First'; sku='F2'; state='Active'; region='West Europe'},
            @{id=$capacity2Id; displayName='Second'; sku='F4'; state='Active'; region='West Europe'}
        )}
        Add-Response GET '/workspaces' 200 @{value=@(@{id=$workspaceId; capacityId=$capacityId})}
        $inventory = @(& "$scripts\07-monitor-capacities.ps1" -ConfigPath $configPath)
        Assert-True ($inventory.Count -eq 2) 'Expected two capacity summaries'
        Assert-True ($inventory[0].AccessibleWorkspaceIds -contains $workspaceId) 'Workspace assignment'
        Assert-True ($null -eq $inventory[0].PSObject.Properties['CU']) 'No fabricated consumption'
    }
    Test-Case 'Uncertain creation retains Pending receipt and blocks replay' {
        Add-Response POST '/workspaces' 0 $null
        Assert-Throws { & "$scripts\03-create-workspace.ps1" -ConfigPath $configPath -StatePath $pendingPath } 'uncertain transport'
        $pending = Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json
        Assert-True ($pending.status -eq 'Pending') 'Pending receipt must survive'
        Assert-Throws { & "$scripts\03-create-workspace.ps1" -ConfigPath $configPath -StatePath $pendingPath } 'Receipt already exists'
    }
    Test-Case 'Workspace creation writes receipt and verifies creator Admin' {
        Add-Response POST '/workspaces' 201 @{id=$workspaceId; displayName='Fabric-API-Demo-01'}
        Add-Response GET "/workspaces/$workspaceId/roleAssignments" 200 @{
            value=@(@{principal=@{id=$global:DemoTestClaims.oid}; role='Admin'})
        }
        $result = & "$scripts\03-create-workspace.ps1" -ConfigPath $configPath -StatePath $statePath
        Assert-True ($result.id -eq $workspaceId) 'Workspace ID'
        $receipt = Read-DemoReceipt -Path $statePath -Config $config
        $body = $global:DemoTestCalls[0].Body | ConvertFrom-Json -AsHashtable
        Assert-True ($receipt.marker -eq $body.description -and $receipt.workspaceId -eq $workspaceId) 'Ownership receipt must match request'
    }
    Test-Case 'Existing receipt blocks duplicate create before HTTP' {
        Assert-Throws { & "$scripts\03-create-workspace.ps1" -ConfigPath $configPath -StatePath $statePath } 'Receipt already exists'
    }
    Test-Case '202 assignment polls until observed Completed, not just capacity ID' {
        Add-Response GET '/capacities' 200 @{value=@(@{id=$capacityId; state='Active'; displayName='Demo'})}
        Add-Response GET "/workspaces/$workspaceId" 200 @{id=$workspaceId}
        Add-Response POST "/workspaces/$workspaceId/assignToCapacity" 202 $null
        Add-Response GET "/workspaces/$workspaceId" 200 @{capacityId=$capacityId; capacityAssignmentProgress='InProgress'}
        Add-Response GET "/workspaces/$workspaceId" 200 @{capacityId=$capacityId; capacityAssignmentProgress='Completed'}
        & "$scripts\04-assign-capacity.ps1" -CapacityId $capacityId -ConfigPath $configPath -StatePath $statePath
        Assert-True ($global:DemoTestCalls.Count -eq 5) 'Must poll beyond InProgress'
    }
    Test-Case 'Assignment failed state is not success' {
        Add-Response GET '/capacities' 200 @{value=@(@{id=$capacityId; state='Active'})}
        Add-Response GET "/workspaces/$workspaceId" 200 @{id=$workspaceId}
        Add-Response POST "/workspaces/$workspaceId/assignToCapacity" 202 $null
        Add-Response GET "/workspaces/$workspaceId" 200 @{capacityAssignmentProgress='Failed'}
        Assert-Throws { & "$scripts\04-assign-capacity.ps1" -CapacityId $capacityId -ConfigPath $configPath -StatePath $statePath } 'assignment failed'
    }
    Test-Case 'Already assigned other capacity is not migrated' {
        Add-Response GET '/capacities' 200 @{value=@(@{id=$capacityId; state='Active'})}
        Add-Response GET "/workspaces/$workspaceId" 200 @{capacityId=$capacity2Id}
        Assert-Throws { & "$scripts\04-assign-capacity.ps1" -CapacityId $capacityId -ConfigPath $configPath -StatePath $statePath } 'refuses to migrate'
    }
    Test-Case 'Role body uses object ID and Admin and is read back' {
        Add-Response GET "/workspaces/$workspaceId/roleAssignments" 200 @{value=@()}
        Add-Response POST "/workspaces/$workspaceId/roleAssignments" 201 @{id='assignment'}
        Add-Response GET "/workspaces/$workspaceId/roleAssignments" 200 @{
            value=@(@{principal=@{id=$userId; type='User'}; role='Admin'})
        }
        & "$scripts\05-add-workspace-admin.ps1" -ConfigPath $configPath -StatePath $statePath
        $body = $global:DemoTestCalls[1].Body | ConvertFrom-Json -AsHashtable
        Assert-True ($body.principal.id -eq $userId -and $body.role -eq 'Admin') 'Must use principal object ID'
    }
    Test-Case 'Existing different role does not silently escalate' {
        Add-Response GET "/workspaces/$workspaceId/roleAssignments" 200 @{
            value=@(@{principal=@{id=$userId; type='User'}; role='Viewer'})
        }
        Assert-Throws { & "$scripts\05-add-workspace-admin.ps1" -ConfigPath $configPath -StatePath $statePath } 'different assignment'
    }
    Test-Case 'Cleanup WhatIf verifies ownership but never deletes' {
        $receipt = Read-DemoReceipt -Path $statePath -Config $config
        Add-Response GET "/workspaces/$workspaceId" 200 @{id=$workspaceId; displayName=$receipt.displayName; description=$receipt.marker}
        & "$scripts\09-cleanup.ps1" -ConfigPath $configPath -StatePath $statePath -ConfirmWorkspaceName $receipt.displayName -WhatIf
        Assert-True ($global:DemoTestCalls.Count -eq 1) 'WhatIf must not delete'
    }
    Test-Case 'Cleanup refuses mismatched ownership marker' {
        $receipt = Read-DemoReceipt -Path $statePath -Config $config
        Add-Response GET "/workspaces/$workspaceId" 200 @{id=$workspaceId; displayName=$receipt.displayName; description='not owned'}
        Assert-Throws { & "$scripts\09-cleanup.ps1" -ConfigPath $configPath -StatePath $statePath -ConfirmWorkspaceName $receipt.displayName -Confirm:$false } 'ownership verification failed'
    }
    Test-Case 'Cleanup checks HTTP 404 before recording Deleted' {
        $receipt = Read-DemoReceipt -Path $statePath -Config $config
        Add-Response GET "/workspaces/$workspaceId" 200 @{id=$workspaceId; displayName=$receipt.displayName; description=$receipt.marker}
        Add-Response DELETE "/workspaces/$workspaceId" 200 $null
        Add-Response GET "/workspaces/$workspaceId" 404 @{errorCode='WorkspaceNotFound'}
        & "$scripts\09-cleanup.ps1" -ConfigPath $configPath -StatePath $statePath -ConfirmWorkspaceName $receipt.displayName -Confirm:$false
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        Assert-True ($saved.status -eq 'Deleted') 'Deletion must be verified'
    }
    Write-Host "$passed tests passed. MOCK ONLY: no Azure/Fabric calls were made."
}
finally {
    Remove-Item -LiteralPath $configPath -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath }
    if (Test-Path -LiteralPath $pendingPath) { Remove-Item -LiteralPath $pendingPath }
    Remove-Item -LiteralPath $temp
    Remove-Item Function:\global:az, Function:\global:Invoke-WebRequest, Function:\global:Start-Sleep -ErrorAction SilentlyContinue
}
