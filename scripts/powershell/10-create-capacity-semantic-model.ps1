#requires -Version 7.2
<#
.SYNOPSIS
Reads collected capacity operation events through Kusto REST and creates a snapshot semantic model.
.DESCRIPTION
Requires an EXISTING Eventstream -> Eventhouse collection. Never reads the Capacity Metrics app model.
Without -Publish, writes a local model definition only. With -Publish, creates and processes a NEW model.
This is a bounded frozen snapshot, not an automatically refreshing Eventhouse connection.
#>
[CmdletBinding()]
param(
    [uri]$KustoQueryUri,
    [string]$Database,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')][string]$TableName = 'CapacityOperationEvents',
    [string]$ConfigPath = "$PSScriptRoot\..\..\config.local.json",
    [guid[]]$CapacityIds,
    [ValidateRange(1, 168)][int]$LookbackHours = 24,
    [ValidateRange(1, 100000)][int]$MaxRows = 10000,
    [string]$ModelName = 'Fabric Capacity Operations - API Snapshot',
    [string]$OutputDirectory = "$PSScriptRoot\..\..\.demo-state\capacity-model-$([guid]::NewGuid())",
    [switch]$Publish,
    [guid]$WorkspaceId = [guid]::Empty
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\FabricDemo.psm1" -Force
Import-Module "$PSScriptRoot\CapacityModel.psm1" -Force
if (-not $KustoQueryUri -or -not $Database) {
    throw 'Capacity event collection is not configured. Supply -KustoQueryUri (KQL database Query URI) and -Database after setting up Eventstream -> Eventhouse. Capacity Metrics alone is NOT an API source. See README: API data to your own semantic model.'
}
if ($KustoQueryUri.Scheme -ne 'https' -or $KustoQueryUri.Host -notmatch '\.(kusto\.fabric\.microsoft\.com|kusto\.data\.microsoft\.com|kusto\.windows\.net)$' -or
    -not $KustoQueryUri.IsDefaultPort -or $KustoQueryUri.UserInfo -or
    $KustoQueryUri.AbsolutePath -ne '/' -or $KustoQueryUri.Query -or $KustoQueryUri.Fragment) {
    throw 'Supply the HTTPS Query URI root copied from the KQL database (not its Ingestion URI or a portal URL).'
}
if ($Publish -and $WorkspaceId -eq [guid]::Empty) { throw '-Publish requires a nonempty target -WorkspaceId.' }
if ([string]::IsNullOrWhiteSpace($ModelName) -or $ModelName.Length -gt 200) { throw 'ModelName must contain 1-200 characters.' }
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
$privateRoot = [IO.Path]::GetFullPath("$PSScriptRoot\..\..\.demo-state") + [IO.Path]::DirectorySeparatorChar
if (-not $outputPath.StartsWith($privateRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must be inside .demo-state: generated model definitions embed operational data and must not enter Git.'
}
if (Test-Path -LiteralPath $outputPath) { throw 'OutputDirectory already exists. Use a fresh path; no prior snapshot is overwritten.' }
$config = Read-DemoConfig -Path $ConfigPath
if (-not $CapacityIds) {
    if (-not $config['capacity1Id'] -or -not $config['capacity2Id']) { throw 'Set both capacity IDs in local config or supply -CapacityIds.' }
    $CapacityIds = @([guid]$config.capacity1Id, [guid]$config.capacity2Id)
}
$query = New-CapacityEventsQuery -TableName $TableName -CapacityIds $CapacityIds -LookbackHours $LookbackHours -MaxRows $MaxRows
$kustoToken = Get-DemoAccessToken -Config $config -Resource 'https://api.kusto.windows.net'
$context = @{BaseUrl=$KustoQueryUri.AbsoluteUri.TrimEnd('/'); Token=$kustoToken.Token}
$response = Invoke-FabricRequest -Context $context -Method POST -Path '/v2/rest/query' -Body @{
    db=$Database; csl=$query
    properties=@{Options=@{results_progressive_enabled=$false; servertimeout='00:00:45'}}
}
$records = @(ConvertFrom-CapacityQueryResponse -Frames $response.Data -MaxRows $MaxRows)
foreach ($capacity in $CapacityIds) {
    if (-not @($records | Where-Object CapacityId -eq $capacity.ToString()).Count) {
        Write-Warning "No events returned for capacity $capacity in this window. This is not proof of zero consumption."
    }
}
$definition = New-CapacitySnapshotDefinition -Records $records
$body = @{
    displayName=$ModelName
    description='Capacity operation events fetched by API. Frozen snapshot; not live or smoothed utilization.'
    definition=$definition.Definition
}
$requestJson = $body | ConvertTo-Json -Depth 10
if ([Text.Encoding]::UTF8.GetByteCount($requestJson) -gt 8MB) {
    throw 'Model payload exceeds the demo 8 MiB safety budget. Reduce the time window; no partial model is published.'
}
$null = New-Item -ItemType Directory -Path $outputPath
$definition.ModelJson | Set-Content -LiteralPath "$outputPath\model.bim" -Encoding utf8
$definition.Pbism | Set-Content -LiteralPath "$outputPath\definition.pbism" -Encoding utf8
ConvertTo-Json -InputObject $records -Depth 5 | Set-Content -LiteralPath "$outputPath\capacity-operations.json" -Encoding utf8
$receipt = @{
    tenantId=$config.tenantId; workspaceId=$WorkspaceId.ToString(); modelName=$ModelName
    recordCount=$records.Count; extractedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
    lookbackHours=$LookbackHours; status='Exported'; modelId=''
}
$receiptPath = "$outputPath\receipt.json"
Save-DemoReceipt -Path $receiptPath -Receipt $receipt
Write-Host "Exported $($records.Count) real records and a snapshot model definition to $outputPath"
if (-not $Publish) {
    Write-Host 'Local definition only: no cloud model was created. Use -Publish -WorkspaceId with a fresh OutputDirectory to create/process it.'
    return
}
$fabric = Get-FabricContext -Config $config
$powerBi = Get-DemoAccessToken -Config $config -Resource 'https://analysis.windows.net/powerbi/api'
$powerBi.BaseUrl = 'https://api.powerbi.com/v1.0/myorg'
$receipt.status = 'CreationPending'
Save-DemoReceipt -Path $receiptPath -Receipt $receipt
$created = Invoke-FabricRequest -Context $fabric -Method POST -Path "/workspaces/$WorkspaceId/semanticModels" `
    -Body $body -ExpectedStatus @(201, 202)
$receipt.operationId = [string]@($created.Headers['x-ms-operation-id'])[0]
if ($created.Data -and $created.Data['id']) { $receipt.modelId = $created.Data.id }
Save-DemoReceipt -Path $receiptPath -Receipt $receipt
$model = Wait-CapacityModelCreation -Context $fabric -Response $created
$modelId = [guid]$model['id']
if ($modelId -eq [guid]::Empty) { throw 'Creation completed without a model ID; inspect receipt before retrying.' }
$receipt.modelId = $modelId.ToString()
$receipt.status = 'CreatedNotProcessed'
Save-DemoReceipt -Path $receiptPath -Receipt $receipt
Write-Host "Created semantic model $modelId in workspace $WorkspaceId."
Invoke-CapacitySnapshotRefresh -Context $powerBi -WorkspaceId $WorkspaceId -ModelId $modelId
$receipt.status = 'Processed'
Save-DemoReceipt -Path $receiptPath -Receipt $receipt
[pscustomobject]@{
    WorkspaceId=$WorkspaceId; SemanticModelId=$modelId; Rows=$records.Count; SnapshotUtc=$receipt.extractedAtUtc
    OutputDirectory=$outputPath; Status='Processed'
}
