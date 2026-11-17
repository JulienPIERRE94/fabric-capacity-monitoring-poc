#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-CapacityReportDefinition {
    param(
        [guid]$ModelId = [guid]::Empty,
        [guid]$WorkspaceId = [guid]::Empty,
        [string]$LocalModelPath = '../CapacityMonitoring.SemanticModel',
        [Parameter(Mandatory)][DateTimeOffset]$SnapshotUtc
    )
    $files = [ordered]@{}
    $root = 'https://developer.microsoft.com/json-schemas/fabric/item/report'
    $reference = if ($ModelId -ne [guid]::Empty) {
        if ($WorkspaceId -eq [guid]::Empty) { throw 'A cloud model reference requires WorkspaceId.' }
        @{byConnection=@{connectionString="Data Source=powerbi://api.powerbi.com/v1.0/myorg/$WorkspaceId;Initial Catalog=$ModelId;Integrated Security=ClaimsToken;semanticModelId=$ModelId"}}
    } else { @{byPath=@{path=$LocalModelPath}} }
    $files['definition.pbir'] = @{
        '$schema'="$root/definitionProperties/2.0.0/schema.json"; version='4.0'; datasetReference=$reference
    }
    $files['definition/version.json'] = @{
        '$schema'="$root/definition/versionMetadata/1.0.0/schema.json"; version='2.0.0'
    }
    $files['definition/report.json'] = @{
        '$schema'="$root/definition/report/3.3.0/schema.json"; themeCollection=@{}
        settings=@{allowChangeFilterTypes=$true; useEnhancedTooltips=$true}
    }
    $pages = @('synthese','workspaces','operations')
    $files['definition/pages/pages.json'] = @{
        '$schema'="$root/definition/pagesMetadata/1.1.0/schema.json"
        pageOrder=$pages; activePageName='synthese'
    }
    function Field([string]$Name, [bool]$Measure = $false) {
        $kind = if ($Measure) { 'Measure' } else { 'Column' }
        return @{$kind=@{Expression=@{SourceRef=@{Entity='CapacityOperations'}}; Property=$Name}}
    }
    function Projection([string]$Name, [bool]$Measure = $false) {
        return @{field=(Field $Name $Measure); queryRef="CapacityOperations.$Name"; nativeQueryRef=$Name}
    }
    function Literal([string]$Value) { return @{expr=@{Literal=@{Value=$Value}}} }
    function Visual($Page, $Name, $Type, $X, $Y, $Width, $Height, $Title, $Roles) {
        $visual = @{
            '$schema'="$root/definition/visualContainer/2.10.0/schema.json"; name=$Name
            position=@{x=$X; y=$Y; z=0; width=$Width; height=$Height}
            visual=@{
                visualType=$Type
                visualContainerObjects=@{
                    title=@(@{properties=@{show=(Literal 'true'); text=(Literal ("'" + $Title.Replace("'", "''") + "'"))}})
                }
            }
        }
        if ($Roles) { $visual.visual.query=@{queryState=$Roles} }
        $files["definition/pages/$Page/visuals/$Name/visual.json"] = $visual
        return $visual
    }
    function Text($Page, $Name, $Text, $Y, $Size, $Height) {
        $v = Visual $Page $Name 'textbox' 24 $Y 1232 $Height '' $null
        $v.visual.Remove('visualContainerObjects')
        $v.visual.objects=@{general=@(@{properties=@{paragraphs=@(@{
            textRuns=@(@{value=$Text; textStyle=@{fontFamily='Segoe UI'; fontSize="$($Size)pt"; color='#12263A'}})
        })}})}
    }
    function Card($Page, $Name, $Measure, $Title, $X) {
        $null = Visual $Page $Name 'card' $X 184 290 110 $Title @{
            Values=@{projections=@((Projection $Measure $true))}
        }
    }
    function Bar($Page, $Name, $Column, $Title, $X, $Y, $Width, $Height) {
        $v = Visual $Page $Name 'barChart' $X $Y $Width $Height $Title @{
            Category=@{projections=@((Projection $Column))}
            Y=@{projections=@((Projection 'CU Seconds' $true))}
        }
        $v.visual.query.sortDefinition=@{sort=@(@{field=(Field 'CU Seconds' $true); direction='Descending'})}
    }
    $titles = @{synthese='Consommation Fabric - Synthese'; workspaces='Workspaces et elements'; operations='Operations et delais signales'}
    foreach ($page in $pages) {
        $files["definition/pages/$page/page.json"] = @{
            '$schema'="$root/definition/page/2.1.0/schema.json"; name=$page
            displayName=$titles[$page]; displayOption='FitToPage'; width=1280; height=1000
        }
        Text $page 'titre' $titles[$page] 12 24 48
        Text $page 'statut' ("Instantane API du " + $SnapshotUtc.UtcDateTime.ToString('yyyy-MM-dd HH:mm') + " UTC - donnees des deux regions") 62 11 32
        $null = Visual $page 'capacite' 'slicer' 24 96 600 72 'Capacite' @{
            Values=@{projections=@((Projection 'CapacityName'))}
        }
        $null = Visual $page 'periode' 'slicer' 656 96 600 72 'Date des evenements (UTC)' @{
            Values=@{projections=@((Projection 'EventTimeUtc'))}
        }
        Card $page 'cu' 'CU Seconds' 'Consommation (CU secondes)' 24
        Card $page 'evenements' 'Event Records' 'Evenements recus' 338
        Card $page 'duree' 'Duration Seconds' 'Durees cumulees (secondes)' 652
        Card $page 'delai' 'Throttling Delay Seconds' 'Delais cumules signales (secondes)' 966
        Text $page 'limites' 'CU brutes des evenements recus : ni utilisation lissee %, ni preuve de couverture exhaustive. Instantane fige, pas de rafraichissement automatique.' 940 10 44
    }
    Bar 'synthese' 'parcapacite' 'CapacityName' 'CU secondes par capacite' 24 314 600 250
    Bar 'synthese' 'parworkload' 'ItemKind' 'CU secondes par type d''element' 656 314 600 250
    $null = Visual 'synthese' 'chronologie' 'lineChart' 24 584 1232 330 'Consommation par horodatage d''evenement (UTC)' @{
        Category=@{projections=@((Projection 'EventTimeUtc'))}
        Y=@{projections=@((Projection 'CU Seconds' $true))}
    }
    Bar 'workspaces' 'parworkspace' 'WorkspaceName' 'CU secondes par workspace' 24 314 600 290
    Bar 'workspaces' 'parelement' 'ItemName' 'CU secondes par element' 656 314 600 290
    $workspaceColumns = @('CapacityName','WorkspaceName','ItemName','ItemKind')
    $null = Visual 'workspaces' 'detailworkspaces' 'tableEx' 24 624 1232 290 'Detail des consommations' @{
        Values=@{projections=@(
            foreach ($column in $workspaceColumns) { Projection $column }
            foreach ($measure in 'CU Seconds','Event Records','Duration Seconds','Throttling Delay Seconds') { Projection $measure $true }
        )}
    }
    Bar 'operations' 'paroperation' 'OperationName' 'CU secondes par operation' 24 314 600 250
    $null = Visual 'operations' 'delayed' 'card' 656 314 290 110 'Evenements avec delai > 0' @{
        Values=@{projections=@((Projection 'Delayed Event Records' $true))}
    }
    $null = Visual 'operations' 'observed' 'card' 966 314 290 110 'Operations identifiees (hors ID vides)' @{
        Values=@{projections=@((Projection 'Observed Operations' $true))}
    }
    $null = Visual 'operations' 'detailoperations' 'tableEx' 24 584 1232 330 'Evenements : durees et delais ne sont pas la consommation CU' @{
        Values=@{projections=@(
            foreach ($column in 'EventTimeUtc','CapacityName','WorkspaceName','ItemName','OperationName','OperationId','Status','UtilizationType') { Projection $column }
            foreach ($measure in 'CU Seconds','Duration Seconds','Throttling Delay Seconds') { Projection $measure $true }
        )}
    }
    $parts = @(
        foreach ($entry in $files.GetEnumerator()) {
            $json = ConvertTo-Json -InputObject $entry.Value -Depth 50
            @{path=$entry.Key; payloadType='InlineBase64'; payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))}
        }
    )
    return @{Files=$files; Definition=@{parts=$parts}}
}

Export-ModuleMember -Function New-CapacityReportDefinition
