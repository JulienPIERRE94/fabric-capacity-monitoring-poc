#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\scripts\powershell\CapacityReport.psm1" -Force
Import-Module "$PSScriptRoot\..\scripts\powershell\CapacityModel.psm1"
Import-Module "$PSScriptRoot\..\scripts\powershell\FabricDemo.psm1"
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$snapshot = [DateTimeOffset]'2026-11-16T15:00:00Z'
$report = New-CapacityReportDefinition -SnapshotUtc $snapshot
$pages = $report.Files['definition/pages/pages.json'].pageOrder
Assert ($pages.Count -eq 3) 'Expected the three requested report pages.'
$columns = @('EventId','EventTimeUtc','CapacityId','CapacityName','CapacitySku','WorkspaceId','WorkspaceName',
    'ItemId','ItemName','ItemKind','OperationId','OperationName','Status','UtilizationType',
    'OperationStartUtc','CapacityUnitMs','DurationMs','ThrottlingDelayMs')
$model = (New-CapacitySnapshotDefinition -Records @([pscustomobject]@{EventId='test'})).ModelJson | ConvertFrom-Json -AsHashtable
$measures = @($model.model.tables[0].measures | ForEach-Object { $_.name })
foreach ($page in $pages) {
    $pageDefinition = $report.Files["definition/pages/$page/page.json"]
    $visuals = @($report.Files.GetEnumerator() | Where-Object { $_.Key.StartsWith("definition/pages/$page/visuals/") })
    Assert ($visuals.Count -ge 10) "Missing visuals on $page"
    foreach ($visual in $visuals) {
        $position = $visual.Value.position
        Assert ($position.x -ge 0 -and $position.y -ge 0 -and
            $position.x + $position.width -le $pageDefinition.width -and
            $position.y + $position.height -le $pageDefinition.height) "Visual out of canvas: $($visual.Key)"
        if ($visual.Value.visual.ContainsKey('query')) {
            foreach ($role in $visual.Value.visual.query.queryState.Values) {
                foreach ($projection in $role.projections) {
                    if ($projection.field.ContainsKey('Measure')) {
                        Assert ($projection.field.Measure.Property -in $measures) 'Unbound report measure'
                    } else { Assert ($projection.field.Column.Property -in $columns) 'Unbound report column' }
                }
            }
        }
    }
    $footer = $report.Files["definition/pages/$page/visuals/limites/visual.json"] | ConvertTo-Json -Depth 30
    Assert ($footer.Contains('Instantane fige') -and $footer.Contains('ni utilisation lissee')) 'Snapshot limitations must be visible on every page.'
}
Write-Output 'PASS: report pages, canvas bounds, field/measure bindings and visible snapshot limitations'
foreach ($part in $report.Definition.parts) {
    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.payload)) | ConvertFrom-Json -AsHashtable
    Assert ($decoded.ContainsKey('$schema')) "Missing schema in $($part.path)"
    Assert ($part.path -in $report.Files.Keys) 'Definition part does not match local report'
}
Assert ($report.Files['definition.pbir'].datasetReference.byPath.path -eq '../CapacityMonitoring.SemanticModel') 'Local model reference'
$modelId = [guid]'88888888-8888-8888-8888-888888888888'
$workspace = [guid]'66666666-6666-6666-6666-666666666666'
$cloud = New-CapacityReportDefinition -ModelId $modelId -WorkspaceId $workspace -SnapshotUtc $snapshot
$connection = $cloud.Files['definition.pbir'].datasetReference.byConnection.connectionString
Assert ($connection.Contains($modelId.ToString()) -and $connection.Contains($workspace.ToString())) 'Wrong remote model binding'
Assert ($connection.Contains("semanticModelId=$modelId")) 'Fabric report creation requires the explicit semanticModelId connection parameter.'
Write-Output 'PASS: complete JSON/Base64 definitions and distinct local/cloud semantic model bindings'
$config = @{tenantId='11111111-1111-1111-1111-111111111111'; clientId='22222222-2222-2222-2222-222222222222'}
$global:ReportTestClaims = @{tid=$config.tenantId; appid='33333333-3333-3333-3333-333333333333'; scp='Item.ReadWrite.All'; exp=[DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds(); aud='https://api.fabric.microsoft.com'; oid='test-user'}
function global:az {
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($global:ReportTestClaims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
    $global:LASTEXITCODE=0
    @{accessToken="test.$payload.signature"} | ConvertTo-Json -Compress
}
try {
    $denied=$false
    try { $null=Get-DemoAccessToken -Config $config } catch { $denied=$true }
    Assert $denied 'Delegated tokens must still be rejected by default.'
    $null=Get-DemoAccessToken -Config $config -DelegatedUser
    $global:ReportTestClaims.tid='44444444-4444-4444-4444-444444444444'
    $denied=$false
    try { $null=Get-DemoAccessToken -Config $config -DelegatedUser } catch { $denied=$true }
    Assert $denied 'Opt-in user authentication must reject another tenant.'
    Write-Output 'PASS: explicit delegated-user opt-in preserves default app-only and tenant guards'
}
finally {
    Remove-Item Function:\az
    Remove-Variable ReportTestClaims -Scope Global
}
