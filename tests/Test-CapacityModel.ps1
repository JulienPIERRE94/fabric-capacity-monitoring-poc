#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath("$PSScriptRoot\..")
Import-Module "$root\scripts\powershell\CapacityModel.psm1" -Force
Import-Module "$root\scripts\powershell\FabricDemo.psm1"
$capacityId = '44444444-4444-4444-4444-444444444444'
$workspaceId = '66666666-6666-6666-6666-666666666666'
$modelId = '88888888-8888-8888-8888-888888888888'
$operationId = '99999999-9999-9999-9999-999999999999'
$global:CapacityModelQueue = [Collections.Generic.Queue[hashtable]]::new()
$global:CapacityModelCalls = [Collections.Generic.List[hashtable]]::new()
$global:CapacityModelSleeps = [Collections.Generic.List[int]]::new()
$global:CapacityModelClaims = @{
    tid='11111111-1111-1111-1111-111111111111'; appid='22222222-2222-2222-2222-222222222222'
    oid='33333333-3333-3333-3333-333333333333'; exp=[DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
    aud='https://api.fabric.microsoft.com'
}
$config = @{
    tenantId=$global:CapacityModelClaims.tid; clientId=$global:CapacityModelClaims.appid
    fabricApiBaseUrl='https://api.fabric.microsoft.com/v1'; capacity1Id=$capacityId
    capacity2Id='55555555-5555-5555-5555-555555555555'
}
$testFolder = Join-Path $root ".demo-state\capacity-model-tests-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $testFolder
$configPath = Join-Path $testFolder 'config.json'
$config | ConvertTo-Json | Set-Content -LiteralPath $configPath
$passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $failure = $null
    try { $null = & $Action } catch { $failure = $_ }
    Assert-True ($null -ne $failure) "Expected error matching $Pattern"
    Assert-True ($failure.Exception.Message -match $Pattern) "Unexpected error: $($failure.Exception.Message)"
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    $global:CapacityModelQueue.Clear(); $global:CapacityModelCalls.Clear(); $global:CapacityModelSleeps.Clear()
    & $Action
    Assert-True ($global:CapacityModelQueue.Count -eq 0) "Unused HTTP responses in $Name"
    $script:passed++
    Write-Host "PASS: $Name"
}
function Add-Response([string]$Method, [string]$Uri, [int]$Status, [object]$Data, [hashtable]$Headers = @{}) {
    $global:CapacityModelQueue.Enqueue(@{Method=$Method; Uri=$Uri; Status=$Status; Data=$Data; Headers=$Headers})
}
function New-TestFrames {
    $columns = @('EventId','EventTimeUtc','CapacityId','CapacityName','CapacitySku','WorkspaceId','WorkspaceName',
        'ItemId','ItemName','ItemKind','OperationId','OperationName','Status','UtilizationType',
        'OperationStartUtc','CapacityUnitMs','DurationMs','ThrottlingDelayMs')
    $row = @('event-1','2026-11-16T13:00:00Z',$capacityId,'Demo','F64',$workspaceId,'Demo workspace',
        'item-1','Demo item','Lakehouse','run-1','Lakehouse Operations','Success','Background',
        '2026-11-16T12:59:00Z',12345.5,30000,0)
    return @(
        @{FrameType='DataSetHeader'; IsProgressive=$false},
        @{FrameType='DataTable'; TableKind='PrimaryResult'; Columns=@($columns | ForEach-Object { @{ColumnName=$_} }); Rows=@(,$row)},
        @{FrameType='DataSetCompletion'; HasErrors=$false; Cancelled=$false}
    )
}
function global:az {
    $global:LASTEXITCODE = 0
    if (($args -join ' ') -notmatch 'account get-access-token') { throw 'No real CLI operations allowed in tests.' }
    $resourceIndex = [array]::IndexOf($args, '--resource')
    if ($resourceIndex -lt 0) { throw 'Token request must specify its own API resource.' }
    $global:CapacityModelClaims.aud = $args[$resourceIndex + 1]
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        ($global:CapacityModelClaims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
    @{accessToken="test.$payload.not-a-signature"} | ConvertTo-Json -Compress
}
function global:Start-Sleep([int]$Seconds) { $global:CapacityModelSleeps.Add($Seconds) }
function global:Invoke-WebRequest {
    param($Uri,$Method,$Headers,$Body,$ContentType,$MaximumRedirection,$TimeoutSec,[switch]$SkipHttpErrorCheck)
    if ($global:CapacityModelQueue.Count -eq 0) { throw "Unexpected HTTP: $Method $Uri" }
    $expected = $global:CapacityModelQueue.Dequeue()
    if ($expected.Method -ne $Method -or $expected.Uri -cne $Uri) { throw "Unexpected HTTP: $Method $Uri; expected $($expected.Method) $($expected.Uri)" }
    $global:CapacityModelCalls.Add(@{Method=$Method; Uri=$Uri; Body=$Body})
    [pscustomobject]@{
        StatusCode=$expected.Status; Headers=$expected.Headers
        Content=if ($null -ne $expected.Data) { ConvertTo-Json -InputObject $expected.Data -Depth 20 -Compress } else { '' }
    }
}

try {
    Test-Case 'No source fails before credentials or HTTP; no fake CU model' {
        Assert-Throws { & "$root\scripts\powershell\10-create-capacity-semantic-model.ps1" } 'collection is not configured'
    }
    Test-Case 'Query is capacity/time scoped, deduplicates envelope ID and detects row overflow' {
        $query = New-CapacityEventsQuery -CapacityIds $capacityId -LookbackHours 6 -MaxRows 10
        Assert-True ($query.Contains('ago(6h)') -and $query.Contains($capacityId) -and $query.Contains('by id') -and $query.Contains('take 11')) 'Required query guards'
        Assert-True ($query.Contains("where ['time'] >") -and $query.Contains("arg_max(['time'], *)") -and $query.Contains("EventTimeUtc=['time']")) 'Reserved time column must be quoted in KQL'
        Assert-Throws { New-CapacityEventsQuery -TableName 'Events; drop table' -CapacityIds $capacityId } 'TableName'
    }
    Test-Case 'HTTP 200 partial failures and incomplete responses cannot become models' {
        $frames = New-TestFrames; $frames[2].HasErrors = $true
        Assert-Throws { ConvertFrom-CapacityQueryResponse -Frames $frames } 'partial'
        $frames = New-TestFrames
        Assert-Throws { ConvertFrom-CapacityQueryResponse -Frames $frames[0..1] } 'incomplete'
        $frames[2].Cancelled = $true
        Assert-Throws { ConvertFrom-CapacityQueryResponse -Frames $frames } 'cancelled'
    }
    Test-Case 'Missing CU and zero rows fail rather than manufacturing zeros' {
        $frames = New-TestFrames; $frames[1].Rows[0][15] = $null
        Assert-Throws { ConvertFrom-CapacityQueryResponse -Frames $frames } 'null consumption is not zero'
        $frames = New-TestFrames; $frames[1].Rows = @()
        Assert-Throws { ConvertFrom-CapacityQueryResponse -Frames $frames } 'No capacity events'
    }
    Test-Case 'Oversize extraction is rejected; event duplicates are not silently loaded' {
        $frames = New-TestFrames
        $frames[1].Rows = @($frames[1].Rows[0], $frames[1].Rows[0])
        Assert-Throws { ConvertFrom-CapacityQueryResponse -Frames $frames -MaxRows 1 } 'More than 1'
        Assert-Throws { ConvertFrom-CapacityQueryResponse -Frames $frames } 'Duplicate event ID'
    }
    Test-Case 'Snapshot has the API records, typed columns and raw-CU measures without external credentials' {
        # Round-trip through JSON reproduces timestamps converted by ConvertFrom-Json.
        $frames = ConvertTo-Json -InputObject (New-TestFrames) -Depth 10 | ConvertFrom-Json -AsHashtable
        $records = @(ConvertFrom-CapacityQueryResponse -Frames $frames)
        Assert-True ($records.Count -eq 1 -and $records[0].CapacityUnitMs -eq 12345.5 -and $records[0].EventTimeUtc -eq '2026-11-16T13:00:00.0000000') 'Exact source record and UTC'
        $definition = New-CapacitySnapshotDefinition -Records $records
        $model = $definition.ModelJson | ConvertFrom-Json -AsHashtable
        $expression = $model.model.tables[0].partitions[0].source.expression -join "`n"
        $encoded = [regex]::Match($expression, 'Binary.FromText\("([^"]+)"').Groups[1].Value
        $snapshot = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json -AsHashtable -NoEnumerate
        Assert-True ($snapshot.Count -eq 1 -and $snapshot[0].OperationId -eq 'run-1') 'Embedded real snapshot'
        $cu = @($model.model.tables[0].measures | Where-Object name -eq 'CU Seconds')[0]
        Assert-True ($cu.expression.Contains('1000') -and $model.model.tables[0].columns.Count -eq 18) 'CU unit conversion and fields'
        Assert-True (-not $expression.Contains('Web.Contents') -and -not $expression.Contains('Bearer')) 'No embedded API credential or dynamic REST refresh'
    }
    Test-Case 'Events without operation IDs remain records, not invented observed operations' {
        foreach ($sourceId in @('', $null)) {
            $frames = New-TestFrames
            $frames[1].Rows[0][10] = $sourceId
            $records = @(ConvertFrom-CapacityQueryResponse -Frames $frames)
            Assert-True ($records.Count -eq 1 -and $records[0].EventId -eq 'event-1' -and $records[0].OperationId -ceq '') 'Preserve the event and its blank operation ID'
            $definition = New-CapacitySnapshotDefinition -Records $records
            $model = $definition.ModelJson | ConvertFrom-Json -AsHashtable
            $observed = @($model.model.tables[0].measures | Where-Object name -eq 'Observed Operations')[0]
            Assert-True ($observed.expression.Contains('FILTER(''CapacityOperations'', ''CapacityOperations''[OperationId] <> "")')) 'Exclude blank operation IDs from observed operations'
        }
    }
    Test-Case 'Missing operation start stays null while the event timestamp remains required' {
        $frames = New-TestFrames
        $frames[1].Rows[0][14] = $null
        $records = @(ConvertFrom-CapacityQueryResponse -Frames $frames)
        Assert-True ($records.Count -eq 1 -and $null -eq $records[0].OperationStartUtc) 'Do not invent an operation start from the event timestamp'
        $definition = New-CapacitySnapshotDefinition -Records $records
        $model = $definition.ModelJson | ConvertFrom-Json -AsHashtable
        $expression = $model.model.tables[0].partitions[0].source.expression -join "`n"
        $encoded = [regex]::Match($expression, 'Binary.FromText\("([^"]+)"').Groups[1].Value
        $snapshot = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json -AsHashtable -NoEnumerate
        Assert-True ($null -eq $snapshot[0].OperationStartUtc) 'Snapshot preserves the missing timestamp as JSON null'
        $frames[1].Rows[0][1] = $null
        Assert-Throws { ConvertFrom-CapacityQueryResponse -Frames $frames } 'Missing EventTimeUtc'
    }
    Test-Case '202 creation honors Retry-After, waits for Succeeded and retrieves actual result' {
        $context = @{BaseUrl='https://api.fabric.microsoft.com/v1'; Token='test'}
        $accepted = @{Status=202; Data=$null; Headers=@{'x-ms-operation-id'=$operationId; 'Retry-After'='9'}}
        Add-Response GET "https://api.fabric.microsoft.com/v1/operations/$operationId" 200 @{status='Running'} @{'Retry-After'='2'}
        Add-Response GET "https://api.fabric.microsoft.com/v1/operations/$operationId" 200 @{status='Succeeded'}
        Add-Response GET "https://api.fabric.microsoft.com/v1/operations/$operationId/result" 200 @{id=$modelId}
        $result = Wait-CapacityModelCreation -Context $context -Response $accepted
        Assert-True ($result.id -eq $modelId -and $global:CapacityModelSleeps[0] -eq 9) 'Actual completed result, not accepted'
    }
    Test-Case 'Failed creation does not return a successful model' {
        $context = @{BaseUrl='https://api.fabric.microsoft.com/v1'; Token='test'}
        Add-Response GET "https://api.fabric.microsoft.com/v1/operations/$operationId" 200 @{status='Failed'; error=@{errorCode='CorruptedPayload'}}
        Assert-Throws { Wait-CapacityModelCreation -Context $context -Response @{
            Status=202; Data=$null; Headers=@{'x-ms-operation-id'=$operationId}
        } } 'creation Failed'
    }
    Test-Case 'An accepted create that exceeds the wait budget is not replayed' {
        Assert-Throws { Wait-CapacityModelCreation -Context @{BaseUrl='https://api.fabric.microsoft.com/v1'; Token='test'} `
            -TimeoutSeconds 30 -Response @{Status=202; Data=$null; Headers=@{
                'x-ms-operation-id'=$operationId; 'Retry-After'='60'
            }} } 'do not replay POST'
    }
    Test-Case 'Default export makes only a read-only query and never creates a cloud model' {
        $queryUri = 'https://test.z1.kusto.fabric.microsoft.com'
        Add-Response POST "$queryUri/v2/rest/query" 200 (New-TestFrames)
        & "$root\scripts\powershell\10-create-capacity-semantic-model.ps1" `
            -KustoQueryUri $queryUri -Database 'Monitoring' -CapacityIds $capacityId -ConfigPath $configPath `
            -OutputDirectory "$testFolder\export-only"
        $receipt = Get-Content -LiteralPath "$testFolder\export-only\receipt.json" -Raw | ConvertFrom-Json
        Assert-True ($receipt.status -eq 'Exported' -and -not $receipt.modelId -and $global:CapacityModelCalls.Count -eq 1) 'No model created without explicit Publish'
    }
    Test-Case 'Export then publish creates/processes a model using only collected API data' {
        $queryUri = 'https://test.z1.kusto.fabric.microsoft.com'
        Add-Response POST "$queryUri/v2/rest/query" 200 (New-TestFrames)
        Add-Response POST "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/semanticModels" 201 @{id=$modelId}
        Add-Response POST "https://api.powerbi.com/v1.0/myorg/groups/$workspaceId/datasets/$modelId/refreshes" 202 $null @{'x-ms-request-id'='refresh-1'}
        Add-Response GET "https://api.powerbi.com/v1.0/myorg/groups/$workspaceId/datasets/$modelId/refreshes" 200 @{
            value=@(@{requestId='unrelated-refresh'; status='Completed'}, @{requestId='refresh-1'; status='Unknown'})
        }
        Add-Response GET "https://api.powerbi.com/v1.0/myorg/groups/$workspaceId/datasets/$modelId/refreshes" 200 @{
            value=@(@{requestId='refresh-1'; status='Completed'})
        }
        $result = & "$root\scripts\powershell\10-create-capacity-semantic-model.ps1" `
            -KustoQueryUri $queryUri -Database 'Monitoring' -CapacityIds $capacityId -ConfigPath $configPath `
            -OutputDirectory "$testFolder\published" -Publish -WorkspaceId $workspaceId
        Assert-True ($result.Status -eq 'Processed' -and $result.Rows -eq 1) 'Processed source snapshot'
        $receipt = Get-Content -LiteralPath "$testFolder\published\receipt.json" -Raw | ConvertFrom-Json
        Assert-True ($receipt.modelId -eq $modelId -and $receipt.status -eq 'Processed') 'Persistent actual model ID'
        $create = $global:CapacityModelCalls[1].Body | ConvertFrom-Json -AsHashtable
        Assert-True ($create.definition.parts[0].path -eq 'model.bim') 'TMSL create definition'
    }
    Test-Case 'A failed processing request is not reported as a populated model' {
        $context = @{BaseUrl='https://api.powerbi.com/v1.0/myorg'; Token='test'}
        $uri = "https://api.powerbi.com/v1.0/myorg/groups/$workspaceId/datasets/$modelId/refreshes"
        Add-Response POST $uri 202 $null @{'x-ms-request-id'='refresh-2'}
        Add-Response GET $uri 200 @{value=@(@{requestId='refresh-2'; status='Failed'; serviceExceptionJson='Processing failed'})}
        Assert-Throws { Invoke-CapacitySnapshotRefresh -Context $context -WorkspaceId $workspaceId -ModelId $modelId } 'refresh Failed'
    }
    Test-Case 'Processing failure preserves the created model ID and does not retry creation' {
        $queryUri = 'https://test.z1.kusto.fabric.microsoft.com'
        Add-Response POST "$queryUri/v2/rest/query" 200 (New-TestFrames)
        Add-Response POST "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/semanticModels" 201 @{id=$modelId}
        Add-Response POST "https://api.powerbi.com/v1.0/myorg/groups/$workspaceId/datasets/$modelId/refreshes" 202 $null @{'x-ms-request-id'='refresh-3'}
        Add-Response GET "https://api.powerbi.com/v1.0/myorg/groups/$workspaceId/datasets/$modelId/refreshes" 200 @{
            value=@(@{requestId='refresh-3'; status='Failed'; serviceExceptionJson='Processing failed'})
        }
        Assert-Throws { & "$root\scripts\powershell\10-create-capacity-semantic-model.ps1" `
            -KustoQueryUri $queryUri -Database 'Monitoring' -CapacityIds $capacityId -ConfigPath $configPath `
            -OutputDirectory "$testFolder\processing-failed" -Publish -WorkspaceId $workspaceId } 'refresh Failed'
        $receipt = Get-Content -LiteralPath "$testFolder\processing-failed\receipt.json" -Raw | ConvertFrom-Json
        Assert-True ($receipt.modelId -eq $modelId -and $receipt.status -eq 'CreatedNotProcessed') 'Failure does not lose ownership or mark model Processed'
    }
    Write-Host "$passed capacity model tests passed. MOCK ONLY: no Azure/Fabric calls were made."
}
finally {
    # Delete only the explicitly named files/directories created by this test run.
    foreach ($directory in 'published','export-only','processing-failed') {
        foreach ($file in 'model.bim','definition.pbism','capacity-operations.json','receipt.json') {
            $path = Join-Path $testFolder "$directory\$file"
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
        $path = Join-Path $testFolder $directory
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    Remove-Item -LiteralPath $configPath
    Remove-Item -LiteralPath $testFolder
    Remove-Item Function:\global:az, Function:\global:Invoke-WebRequest, Function:\global:Start-Sleep -ErrorAction SilentlyContinue
}
