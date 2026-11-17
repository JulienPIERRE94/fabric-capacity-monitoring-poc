# Fabric Capacity Monitoring POC

A generic proof of concept for Microsoft Fabric capacity telemetry, least-privilege
workspace provisioning, and a custom Power BI report.

**This is a POC, not a production monitoring service.** No customer configuration,
collected events, embedded-data semantic models or deployment receipts are included.

## What it does

- Demonstrates workspace creation, capacity assignment and access management with
  an explicitly configured automation identity.
- Reads capacity operation events **already collected in your own KQL databases**
  through the Kusto REST API.
- Generates an import semantic model and a three-page Power BI report: capacity
  summary, workspaces/items, and operations/reported delays.
- Optionally publishes and processes a new model and publishes its report.
- Includes dependency-free mocked PowerShell tests.

**The generated model is a frozen API snapshot.** A normal Power BI refresh reloads
the embedded data; it does not fetch newer Kusto events. Each published run creates
new items rather than updating an existing report.

## Architecture

```text
Capacity operation events
  -> same-region Eventstream
  -> Eventhouse / KQL database
  -> Kusto REST extraction (PowerShell)
  -> frozen import semantic model
  -> Power BI report
```

Eventstream subscribes to native events; it does not periodically poll a capacity
CU REST endpoint. The scripts do not configure the event sources or destinations.
No separate Azure Event Hubs resource is required by this POC.

See [MONITORING.md](MONITORING.md) for collection, telemetry interpretation and the
challenged [PowerShell/Data Lake alternative](MONITORING.md#powershell-and-data-lake-alternative).

## Prerequisites

- PowerShell 7.2+ and Azure CLI.
- Existing supported, active Fabric capacities and appropriately licensed users.
- For the report script: **exactly two** existing regional collections, each with
  the documented table, and an existing destination workspace.
- KQL database read access and target model/report write access.
- Tenant authorization for the identity and operations you use.

Provisioning and source collection have different permissions. Do not assign
tenant administrator or Capacity Admin just to make the reporting reader work.
See [PERMISSIONS.md](PERMISSIONS.md).

## Quick start: generate a local report

From the repository root in a private PowerShell process:

```powershell
Copy-Item .\config.example.json .\config.local.json
Copy-Item .\collection.example.json .\collection.local.json
```

Edit both local files:

- Set `tenantId` to the same tenant in both.
- In the collection file, set the two source capacity IDs, KQL database IDs and
  database **Query URIs**, not ingestion URIs.
- In delegated-user mode, `clientId` is not required by script 11. In app-only mode,
  set it to the application client ID. Do not put credentials in either file.
- For the other scripts, fill the applicable configuration fields; they retain
  app-only identity checks and require `clientId`.

Use ordinary Microsoft sign-in. Optionally isolate the Azure CLI cache outside the
repository in a private, non-synced directory:

```powershell
$env:AZURE_CONFIG_DIR = Join-Path $env:LOCALAPPDATA 'FabricCapacityMonitoringPOC\AzureCli'

az login `
  --tenant '<TENANT-ID>' `
  --scope 'https://api.fabric.microsoft.com/.default' `
  --use-device-code

.\scripts\powershell\11-create-capacity-report.ps1 `
  -WorkspaceId '<TARGET-WORKSPACE-GUID>' `
  -DelegatedUser
```

This makes read-only Kusto queries and writes a local PBIP project; it does not
publish cloud items without `-Publish`. Additional service consent or conditional
access requirements must be resolved through normal tenant administration.

The generated project under `.demo-state` includes:

```text
capacity-report-<unique-id>\
  CapacityMonitoring.pbip
  CapacityMonitoring.Report\
  CapacityMonitoring.SemanticModel\
  receipt.json
```

Keep the PBIP and its associated folders together. The model contains operational
data: Git exclusion is not encryption or authorization.

### Publish a new model and report

```powershell
.\scripts\powershell\11-create-capacity-report.ps1 `
  -WorkspaceId '<TARGET-WORKSPACE-GUID>' `
  -LookbackHours 24 `
  -MaxRowsPerRegion 10000 `
  -DelegatedUser `
  -Publish
```

Keep the output receipt. After a failure, reconcile recorded model/report and
operation IDs before retrying; writes are not automatically replayed. A creation
response of HTTP 202 is not completion.

For app-only use, authenticate as the configured identity first and omit
`-DelegatedUser`. Certificate login is available through
[01-authenticate.ps1](scripts/powershell/01-authenticate.ps1). Protect the private
certificate outside the repository. End-to-end app-only use requires tenant testing;
successful delegated testing is not evidence that these permissions work.

### Single-source model

[10-create-capacity-semantic-model.ps1](scripts/powershell/10-create-capacity-semantic-model.ps1)
supports extraction from a single KQL database and optional model publication.
It does not generate the three-page report. See the script parameter help.

## Supporting scripts

| Scripts | Purpose |
|---|---|
| 00–02 | Prerequisites, app-only authentication, accessible-capacity inventory |
| 03–06 | Guarded demo workspace creation, assignment, role grant and read-back |
| 07 | Two-capacity accessible inventory, **not CU consumption** |
| 08 | Prints a bounded manual Spark SQL workload; does not execute it |
| 09 | Guarded cleanup of workspaces created by the provisioning demo |
| 10 | Single-source frozen snapshot model |
| 11 | Two-source frozen snapshot model and three-page report |

Provisioning scripts require `Fabric-API-Demo-` workspace names and ownership
receipts; they are not an unrestricted workspace management service. Script 04
refuses cross-capacity migration of an already assigned workspace. Script 09 must
not be used to delete arbitrary workspaces.

## Validation and limitations

```powershell
pwsh -NoProfile -File .\tests\Test-FabricDemo.ps1
pwsh -NoProfile -File .\tests\Test-CapacityModel.ps1
pwsh -NoProfile -File .\tests\Test-CapacityReport.ps1
```

Tests use mocks; they do not prove tenant permissions, event coverage or licensing.
See [VALIDATION.md](VALIDATION.md) for evidence and remaining gaps.

- Raw received-event CU seconds are not Capacity Metrics smoothed utilization.
- Missing events are not zero consumption. A zero delay does not prove complete
  absence of throttling.
- The POC does not query the Capacity Metrics app's semantic model; external
  consumption of that model is unsupported.
- No automatic recollection, production alerting, RLS or customer isolation is
  implemented.
- The report script defaults to 24 hours and 10,000 rows per region. Query failures,
  partial results, missing consumption, empty results and overflow fail explicitly.
- No guaranteed monitoring cost or saving has been measured.

## Public repository hygiene

Do not commit local configuration, tenant/resource identifiers, receipts, token
logs, collected event files, generated PBIP/model data or customer documents.
The repository is intentionally created without the history of the original
development workspace.

## Microsoft references

- [Capacity operation event source](https://learn.microsoft.com/en-us/fabric/real-time-intelligence/event-streams/add-source-fabric-capacity-operation-events)
- [Operation event schema](https://learn.microsoft.com/en-us/fabric/real-time-hub/explore-fabric-capacity-operation-events)
- [Event subscription permissions](https://learn.microsoft.com/en-us/fabric/real-time-hub/fabric-events-subscribe-permission)
- [Kusto REST requests](https://learn.microsoft.com/en-us/kusto/api/rest/request?view=microsoft-fabric)
- [Create semantic model](https://learn.microsoft.com/en-us/rest/api/fabric/semanticmodel/items/create-semantic-model)
- [Create report](https://learn.microsoft.com/en-us/rest/api/fabric/report/items/create-report)
- [Capacity Metrics model restrictions](https://learn.microsoft.com/en-us/fabric/enterprise/metrics-app#considerations-and-limitations)

Documentation reviewed: 17 November 2026. Recheck availability and product-specific
limitations before deploying in another tenant.
