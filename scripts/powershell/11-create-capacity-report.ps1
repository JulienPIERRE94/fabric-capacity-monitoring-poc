#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\..\..\config.local.json",
    [string]$CollectionReceiptPath = "$PSScriptRoot\..\..\collection.local.json",
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [ValidateRange(1,168)][int]$LookbackHours = 24,
    [ValidateRange(1,100000)][int]$MaxRowsPerRegion = 10000,
    [string]$OutputDirectory = "$PSScriptRoot\..\..\.demo-state\capacity-report-$([guid]::NewGuid())",
    [switch]$DelegatedUser,
    [switch]$Publish
)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\FabricDemo.psm1" -Force
Import-Module "$PSScriptRoot\CapacityModel.psm1" -Force
Import-Module "$PSScriptRoot\CapacityReport.psm1" -Force
$config = Read-DemoConfig -Path $ConfigPath -DelegatedUser:$DelegatedUser
$collection = Get-Content -LiteralPath $CollectionReceiptPath -Raw | ConvertFrom-Json -AsHashtable
if ($collection.tenantId -ne $config.tenantId) { throw 'Collection and configuration tenants differ.' }
if ($collection.regions.Count -ne 2) { throw 'Expected both regional collections.' }
if ($WorkspaceId -eq [guid]::Empty) { throw 'WorkspaceId must be nonempty.' }
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
$privateRoot = [IO.Path]::GetFullPath("$PSScriptRoot\..\..\.demo-state") + [IO.Path]::DirectorySeparatorChar
if (-not $outputPath.StartsWith($privateRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'OutputDirectory must be inside .demo-state; it contains operational data.' }
if (Test-Path -LiteralPath $outputPath) { throw 'OutputDirectory exists. No duplicate creation or overwrite is attempted.' }
$kusto = Get-DemoAccessToken -Config $config -Resource 'https://api.kusto.windows.net' -DelegatedUser:$DelegatedUser
$records = @(
    foreach ($region in $collection.regions) {
        $uri = [uri]$region.database.queryUri
        if ($uri.Scheme -ne 'https' -or $uri.Host -notmatch '\.kusto\.fabric\.microsoft\.com$' -or
            -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
            throw 'Invalid regional Kusto query endpoint.'
        }
        $query = New-CapacityEventsQuery -CapacityIds ([guid]$region.capacityId) -LookbackHours $LookbackHours -MaxRows $MaxRowsPerRegion
        $response = Invoke-FabricRequest -Context @{BaseUrl=$uri.AbsoluteUri.TrimEnd('/'); Token=$kusto.Token} `
            -Method POST -Path '/v2/rest/query' -Body @{
                db=$region.database.id; csl=$query
                properties=@{Options=@{results_progressive_enabled=$false; servertimeout='00:00:45'}}
            }
        $regionalRecords = @(ConvertFrom-CapacityQueryResponse -Frames $response.Data -MaxRows $MaxRowsPerRegion)
        if (@($regionalRecords | Where-Object CapacityId -ne $region.capacityId).Count) { throw 'Query returned an unexpected source capacity.' }
        $regionalRecords
    }
)
$seen = [Collections.Generic.HashSet[string]]::new()
foreach ($record in $records) {
    if (-not $seen.Add($record.EventId)) { throw 'Duplicate envelope ID across regional sources.' }
}
$snapshotUtc = [DateTimeOffset]::UtcNow
$model = New-CapacitySnapshotDefinition -Records $records
$report = New-CapacityReportDefinition -SnapshotUtc $snapshotUtc
function Write-ReportFiles($Definition, [string]$Directory) {
    foreach ($entry in $Definition.Files.GetEnumerator()) {
        $relative = $entry.Key.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $path = Join-Path $Directory $relative
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $path)
        ConvertTo-Json -InputObject $entry.Value -Depth 50 | Set-Content -LiteralPath $path -Encoding utf8
    }
}
$null = New-Item -ItemType Directory -Path "$outputPath\CapacityMonitoring.SemanticModel"
$model.ModelJson | Set-Content -LiteralPath "$outputPath\CapacityMonitoring.SemanticModel\model.bim" -Encoding utf8
$model.Pbism | Set-Content -LiteralPath "$outputPath\CapacityMonitoring.SemanticModel\definition.pbism" -Encoding utf8
Write-ReportFiles $report "$outputPath\CapacityMonitoring.Report"
@{
    '$schema'='https://developer.microsoft.com/json-schemas/fabric/pbip/pbipProperties/1.0.0/schema.json'
    version='1.0'; artifacts=@(@{report=@{path='CapacityMonitoring.Report'}}); settings=@{enableAutoRecovery=$true}
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$outputPath\CapacityMonitoring.pbip" -Encoding utf8
$receipt = @{
    tenantId=$config.tenantId; workspaceId=$WorkspaceId.ToString(); extractedAtUtc=$snapshotUtc.ToString('o')
    rows=$records.Count; lookbackHours=$LookbackHours; status='Exported'; modelId=''; reportId=''
    regions=@($collection.regions | ForEach-Object { @{capacityId=$_.capacityId; region=$_.region} })
    refreshMode='Frozen API snapshot; rerun extraction to obtain newer events'
}
$receiptPath = "$outputPath\receipt.json"
Save-DemoReceipt -Path $receiptPath -Receipt $receipt
if (-not $Publish) { Write-Host "Local PBIP report created: $outputPath\CapacityMonitoring.pbip"; return }
$fabric = Get-DemoAccessToken -Config $config -DelegatedUser:$DelegatedUser
$fabric.BaseUrl = $config.fabricApiBaseUrl
$powerBi = Get-DemoAccessToken -Config $config -Resource 'https://analysis.windows.net/powerbi/api' -DelegatedUser:$DelegatedUser
$powerBi.BaseUrl = 'https://api.powerbi.com/v1.0/myorg'
$modelBody = @{
    displayName='Fabric Capacity Monitoring - API Snapshot'
    description='Two-region capacity operation events, frozen API snapshot. Refresh does not recollect data.'
    definition=$model.Definition
}
if ([Text.Encoding]::UTF8.GetByteCount(($modelBody | ConvertTo-Json -Depth 10 -Compress)) -gt 8MB) {
    throw 'Model payload exceeds the 8 MiB demo budget. Local files retained; nothing published.'
}
$receipt.status='ModelCreationPending'
Save-DemoReceipt -Path $receiptPath -Receipt $receipt
$accepted = Invoke-FabricRequest -Context $fabric -Method POST -Path "/workspaces/$WorkspaceId/semanticModels" -Body $modelBody -ExpectedStatus @(201,202)
$receipt.modelOperationId=[string]@($accepted.Headers['x-ms-operation-id'])[0]
if ($accepted.Data -and $accepted.Data['id']) { $receipt.modelId=$accepted.Data.id }
Save-DemoReceipt -Path $receiptPath -Receipt $receipt
$createdModel = Wait-CapacityModelCreation -Context $fabric -Response $accepted
$modelId = [guid]$createdModel['id']
if ($modelId -eq [guid]::Empty) { throw 'Model creation returned no ID. Reconcile before retrying.' }
$receipt.modelId=$modelId.ToString(); $receipt.status='ModelCreatedNotProcessed'
Save-DemoReceipt -Path $receiptPath -Receipt $receipt
Invoke-CapacitySnapshotRefresh -Context $powerBi -WorkspaceId $WorkspaceId -ModelId $modelId
$receipt.status='ModelProcessed'
Save-DemoReceipt -Path $receiptPath -Receipt $receipt
$cloudReport = New-CapacityReportDefinition -ModelId $modelId -WorkspaceId $WorkspaceId -SnapshotUtc $snapshotUtc
$receipt.status='ReportCreationPending'
Save-DemoReceipt -Path $receiptPath -Receipt $receipt
$accepted = Invoke-FabricRequest -Context $fabric -Method POST -Path "/workspaces/$WorkspaceId/reports" -ExpectedStatus @(201,202) -Body @{
    displayName='Fabric Capacity Monitoring'
    description='CU seconds, workspaces, items, operations and reported delays. Frozen two-region API snapshot, not utilization %.'
    definition=$cloudReport.Definition
}
$receipt.reportOperationId=[string]@($accepted.Headers['x-ms-operation-id'])[0]
if ($accepted.Data -and $accepted.Data['id']) { $receipt.reportId=$accepted.Data.id }
Save-DemoReceipt -Path $receiptPath -Receipt $receipt
$createdReport = Wait-CapacityModelCreation -Context $fabric -Response $accepted
$reportId = [guid]$createdReport['id']
if ($reportId -eq [guid]::Empty) { throw 'Report creation returned no ID. Reconcile before retrying.' }
$receipt.reportId=$reportId.ToString(); $receipt.status='Published'
$receipt.reportUrl="https://app.powerbi.com/groups/$WorkspaceId/reports/$reportId`?ctid=$($config.tenantId)"
Save-DemoReceipt -Path $receiptPath -Receipt $receipt
Write-Host "Published report: $($receipt.reportUrl)"
[pscustomobject]$receipt
