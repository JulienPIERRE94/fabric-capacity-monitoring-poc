#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\FabricDemo.psm1"

$script:Columns = [ordered]@{
    EventId='string'; EventTimeUtc='dateTime'; CapacityId='string'; CapacityName='string'
    CapacitySku='string'; WorkspaceId='string'; WorkspaceName='string'; ItemId='string'
    ItemName='string'; ItemKind='string'; OperationId='string'; OperationName='string'
    Status='string'; UtilizationType='string'; OperationStartUtc='dateTime'
    CapacityUnitMs='double'; DurationMs='int64'; ThrottlingDelayMs='int64'
}

function New-CapacityEventsQuery {
    param(
        [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')][string]$TableName = 'CapacityOperationEvents',
        [Parameter(Mandatory)][guid[]]$CapacityIds,
        [ValidateRange(1, 168)][int]$LookbackHours = 24,
        [ValidateRange(1, 100000)][int]$MaxRows = 10000
    )
    if ($CapacityIds.Count -eq 0 -or $CapacityIds -contains [guid]::Empty) {
        throw 'At least one nonempty capacity GUID is required.'
    }
    $ids = ($CapacityIds | ForEach-Object { "'$($_.ToString())'" }) -join ','
    $limit = $MaxRows + 1
    return @"
$TableName
| where ['time'] > ago($($LookbackHours)h)
| where type == 'Microsoft.Fabric.CapacityOperationEvents.Operation'
| where tolower(tostring(data.capacityId)) in ($ids)
| summarize arg_max(['time'], *) by id
| project EventId=tostring(id), EventTimeUtc=['time'],
    CapacityId=tolower(tostring(data.capacityId)), CapacityName=tostring(data.capacityName),
    CapacitySku=tostring(data.capacitySku), WorkspaceId=tostring(data.workspaceId),
    WorkspaceName=tostring(data.workspaceName), ItemId=tostring(data.itemId),
    ItemName=tostring(data.itemName), ItemKind=tostring(data.itemKind),
    OperationId=tostring(data.operationId), OperationName=tostring(data.operationName),
    Status=tostring(data.status), UtilizationType=tostring(data.utilizationType),
    OperationStartUtc=todatetime(data.operationStartTime),
    CapacityUnitMs=todouble(data.capacityUnitMs), DurationMs=tolong(data.durationMs),
    ThrottlingDelayMs=tolong(data.throttlingDelayMs)
| take $limit
"@
}

function ConvertFrom-CapacityQueryResponse {
    param([Parameter(Mandatory)][object[]]$Frames, [ValidateRange(1, 100000)][int]$MaxRows = 10000)
    $header = @($Frames | Where-Object { $_['FrameType'] -eq 'DataSetHeader' })
    $completion = @($Frames | Where-Object { $_['FrameType'] -eq 'DataSetCompletion' })
    if ($header.Count -ne 1 -or $header[0]['IsProgressive'] -ne $false -or
        $completion.Count -ne 1 -or $completion[0]['HasErrors'] -ne $false -or $completion[0]['Cancelled'] -ne $false) {
        throw 'Kusto query failed, was partial/cancelled, or returned an unsupported/incomplete response. No model will be created.'
    }
    $tables = @($Frames | Where-Object {
        $_['FrameType'] -eq 'DataTable' -and $_['TableKind'] -eq 'PrimaryResult'
    })
    if ($tables.Count -ne 1) { throw 'Expected exactly one Kusto PrimaryResult table.' }
    $table = $tables[0]
    if ($table['Rows'].Count -eq 0) {
        throw 'No capacity events found. Configure and publish the event collection first, then generate activity. No empty model will be created.'
    }
    if ($table['Rows'].Count -gt $MaxRows) {
        throw "More than $MaxRows records: reduce LookbackHours or explicitly raise MaxRows. A truncated snapshot is not published."
    }
    $names = @($table['Columns'] | ForEach-Object { $_['ColumnName'] })
    if (($names -join ',') -cne ($script:Columns.Keys -join ',')) {
        throw 'Unexpected result columns. Verify the CloudEvent table mapping; do not guess the schema.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new()
    foreach ($row in $table['Rows']) {
        if ($row.Count -ne $names.Count) { throw 'Kusto row/column count mismatch.' }
        $record = [ordered]@{}
        for ($i = 0; $i -lt $names.Count; $i++) {
            $name = $names[$i]
            $value = $row[$i]
            switch ($script:Columns[$name]) {
                dateTime {
                    if (-not $value) {
                        if ($name -ne 'OperationStartUtc') { throw "Missing $name in a source event." }
                        $value = $null
                    }
                    else {
                        $timestamp = if ($value -is [DateTimeOffset]) { $value }
                        elseif ($value -is [DateTime]) { [DateTimeOffset]$value }
                        else {
                            [DateTimeOffset]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture,
                                [Globalization.DateTimeStyles]::AssumeUniversal)
                        }
                        $value = $timestamp.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffffff',
                            [Globalization.CultureInfo]::InvariantCulture)
                    }
                }
                { $_ -in 'double', 'int64' } {
                    if ($null -eq $value) { throw "Missing $name in a source event; null consumption is not zero." }
                    $number = [double]$value
                    if (-not [double]::IsFinite($number) -or $number -lt 0) { throw "Invalid $name in a source event." }
                    $value = if ($script:Columns[$name] -eq 'int64') { [long]$number } else { $number }
                }
                default { $value = [string]$value }
            }
            $record[$name] = $value
        }
        foreach ($required in 'EventId','CapacityId','WorkspaceId','ItemId') {
            if (-not $record[$required]) { throw "Missing $required in a source event. Source mapping/coverage needs investigation." }
        }
        if (-not $seen.Add($record.EventId)) { throw 'Duplicate event ID remains after query deduplication.' }
        [pscustomobject]$record
    }
}

function New-CapacitySnapshotDefinition {
    param([Parameter(Mandatory)][object[]]$Records)
    if ($Records.Count -eq 0) { throw 'Cannot create an empty capacity snapshot.' }
    $json = ConvertTo-Json -InputObject $Records -Depth 5 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $mNames = ($script:Columns.Keys | ForEach-Object { '"' + $_ + '"' }) -join ', '
    $mTypes = ($script:Columns.GetEnumerator() | ForEach-Object {
        $type = switch ($_.Value) { dateTime { 'type datetime' }; double { 'type number' }; int64 { 'Int64.Type' }; default { 'type text' } }
        '{"' + $_.Key + '", ' + $type + '}'
    }) -join ', '
    $expression = @(
        'let',
        "    Snapshot = Json.Document(Binary.FromText(`"$encoded`", BinaryEncoding.Base64)),",
        "    Rows = Table.FromRecords(Snapshot, {$mNames}, MissingField.Error),",
        "    Typed = Table.TransformColumnTypes(Rows, {$mTypes}, `"en-US`")",
        'in',
        '    Typed'
    )
    $columns = @($script:Columns.GetEnumerator() | ForEach-Object {
        @{ name=$_.Key; dataType=$_.Value; sourceColumn=$_.Key; summarizeBy='none' }
    })
    $measures = @(
        @{name='CU Seconds'; expression="DIVIDE(SUM('CapacityOperations'[CapacityUnitMs]), 1000)"; formatString='#,0.000'},
        @{name='Duration Seconds'; expression="DIVIDE(SUM('CapacityOperations'[DurationMs]), 1000)"; formatString='#,0.000'},
        @{name='Throttling Delay Seconds'; expression="DIVIDE(SUM('CapacityOperations'[ThrottlingDelayMs]), 1000)"; formatString='#,0.000'},
        @{name='Event Records'; expression="COUNTROWS('CapacityOperations')"; formatString='#,0'},
        @{name='Observed Operations'; expression="COUNTROWS(SUMMARIZE(FILTER('CapacityOperations', 'CapacityOperations'[OperationId] <> `"`"), 'CapacityOperations'[CapacityId], 'CapacityOperations'[OperationId]))"; formatString='#,0'},
        @{name='Delayed Event Records'; expression="COUNTROWS(FILTER('CapacityOperations', 'CapacityOperations'[ThrottlingDelayMs] > 0))"; formatString='#,0'}
    )
    $model = @{
        compatibilityLevel=1600
        model=@{
            culture='en-US'; sourceQueryCulture='en-US'; defaultPowerBIDataSourceVersion='powerBI_V3'
            annotations=@(@{name='CapacityApiSnapshot'; value='Frozen API snapshot, not live capacity utilization'})
            tables=@(@{
                name='CapacityOperations'; columns=$columns; measures=$measures
                partitions=@(@{name='Snapshot'; mode='import'; source=@{type='m'; expression=$expression}})
            })
        }
    }
    $modelJson = $model | ConvertTo-Json -Depth 20
    $pbism = '{"$schema":"https://developer.microsoft.com/json-schemas/fabric/item/semanticModel/definitionProperties/1.0.0/schema.json","version":"1.0","settings":{"qnaEnabled":false}}'
    $parts = @(
        @{path='model.bim'; payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($modelJson)); payloadType='InlineBase64'},
        @{path='definition.pbism'; payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pbism)); payloadType='InlineBase64'}
    )
    return @{ ModelJson=$modelJson; Pbism=$pbism; Definition=@{parts=$parts} }
}

function Wait-CapacityModelCreation {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][hashtable]$Response,
        [ValidateRange(30, 3600)][int]$TimeoutSeconds = 600
    )
    if ($Response.Status -eq 201) {
        if (-not $Response.Data['id']) { throw 'Create response has no semantic model ID. Reconcile before retrying.' }
        return $Response.Data
    }
    $operationId = [guid]::Empty
    $header = @($Response.Headers['x-ms-operation-id'])[0]
    if (-not [guid]::TryParse([string]$header, [ref]$operationId) -or $operationId -eq [guid]::Empty) {
        throw 'HTTP 202 without a valid x-ms-operation-id. Reconcile the accepted creation before retrying.'
    }
    Write-Host "Creation accepted; operation ID: $operationId"
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $delay = 5
        if ($Response.Headers['Retry-After']) { $delay = [int]@($Response.Headers['Retry-After'])[0] }
        $delay = [Math]::Max(1, $delay)
        if ([DateTimeOffset]::UtcNow.AddSeconds($delay) -ge $deadline) {
            throw "Creation is not confirmed within the wait budget. Inspect operation $operationId; do not replay POST."
        }
        Start-Sleep -Seconds $delay
        $Response = Invoke-FabricRequest -Context $Context -Method GET -Path "/operations/$operationId"
        $status = $Response.Data['status']
        if ($status -in 'Failed','Cancelled') {
            throw "Model creation $status. $($Response.Data['error'] | ConvertTo-Json -Compress)"
        }
        if ($status -eq 'Succeeded') {
            return (Invoke-FabricRequest -Context $Context -Method GET -Path "/operations/$operationId/result").Data
        }
        if ($status -notin 'NotStarted','Running') { throw "Unexpected model creation status: $status" }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Model creation timed out. Inspect operation $operationId before retrying."
}

function Invoke-CapacitySnapshotRefresh {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][guid]$WorkspaceId,
        [Parameter(Mandatory)][guid]$ModelId,
        [ValidateRange(30, 3600)][int]$TimeoutSeconds = 600
    )
    $path = "/groups/$WorkspaceId/datasets/$ModelId/refreshes"
    $response = Invoke-FabricRequest -Context $Context -Method POST -Path $path -ExpectedStatus 202 `
        -Body @{type='full'; commitMode='transactional'; retryCount=0; maxParallelism=1}
    $requestId = [string]@($response.Headers['x-ms-request-id'])[0]
    if (-not $requestId) { throw "Refresh accepted without request ID. Inspect model $ModelId; do not replay POST." }
    Write-Host "Refresh accepted; request ID: $requestId"
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 5
        $history = (Invoke-FabricRequest -Context $Context -Method GET -Path $path).Data
        $matches = @($history['value'] | Where-Object { $_['requestId'] -eq $requestId })
        if ($matches.Count -eq 1) {
            $status = $matches[0]['status']
            if ($status -eq 'Completed') { Write-Host 'Snapshot processing completed.'; return }
            if ($status -in 'Failed','Disabled','Cancelled') {
                throw "Snapshot refresh $status. $($matches[0]['serviceExceptionJson'])"
            }
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Refresh not confirmed within timeout. Inspect model $ModelId and refresh $requestId."
}

Export-ModuleMember -Function New-CapacityEventsQuery, ConvertFrom-CapacityQueryResponse,
    New-CapacitySnapshotDefinition, Wait-CapacityModelCreation, Invoke-CapacitySnapshotRefresh
