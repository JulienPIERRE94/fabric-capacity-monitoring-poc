# Validation record and boundaries

Public package prepared: **17 November 2026**.

## Offline validation

Run the three dependency-free PowerShell test runners from the repository root:

```powershell
pwsh -NoProfile -File .\tests\Test-FabricDemo.ps1
pwsh -NoProfile -File .\tests\Test-CapacityModel.ps1
pwsh -NoProfile -File .\tests\Test-CapacityReport.ps1
git diff --check
```

- Core suite: 21 mocked cases, including parsing, identity checks, safe endpoints,
  pagination, GET retry rules, non-replayed writes and ownership/read-back guards.
- Model suite: 15 mocked cases for extraction, partial/invalid responses, missing
  fields, overflow, nullable operation data, frozen snapshot generation, creation
  completion and processing failure handling.
- Report checks: page generation, canvas bounds, field/measure references, visible
  limitations, local/cloud binding, explicit semantic-model connection parameter
  and delegated opt-in without weakening default tenant/app-only guards.

These are not cloud integration tests. No credentials or live services are needed.
The generated report's 44 JSON parts were also validated against Microsoft schemas
during development; schema validation alone is not rendering validation.

## Previous functional evidence

Before creating this generic package, the collection-to-report path was exercised
in a demonstration environment using delegated authentication:

- Two regional Eventstreams persisted events into their Eventhouse tables.
- Kusto REST queries returned real records.
- A snapshot model was created and fully processed.
- Power BI REST verified model/report binding.
- Service-side DAX totals matched the extracted snapshot.
- All three report pages rendered and a capacity filter changed the results.

No environment IDs, endpoints, captured data or reports from that environment are
published here. The generic package changes report names and local collection
configuration defaults; users must validate deployment in their own tenant.

## Not validated or implemented

- End-to-end least-privilege app-only deployment and source ownership.
- Customer/non-admin reader isolation, licensing and negative access tests.
- Completeness, long-term event latency, workload coverage and utilization parity.
- An automatically recollecting model refresh, production alerts or RLS.
- Eventstream → Lakehouse deployment, cost savings or report integration.
- An incremental PowerShell-to-Data-Lake exporter or scheduler.
- Source setup through the provided scripts; configure it separately.

Do not promote the POC to production without validating these items.
