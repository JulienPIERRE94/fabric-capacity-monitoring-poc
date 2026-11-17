# Collection and monitoring guide

## Configure collection first

For each source capacity:

1. Use a monitoring workspace/consumer in the same region as the capacity.
2. Create an Eventhouse with its KQL database.
3. Create an Eventstream with a **Capacity operation events** source.
4. Select the intended source capacity using an authorized Capacity Admin owner.
5. Add a direct-ingestion Eventhouse destination and publish.
6. Configure a table and JSON mapping preserving the envelope fields below.
7. Query persisted KQL rows, not just Eventstream previews.

The listener owner's Capacity Admin permission must remain for the subscription's
lifetime. Removing it after setup is not a supported least-privilege shortcut.
Source availability and Preview status must be checked in your tenant. The source
documentation also lists specific CI/CD limitations: do not infer full deployment
support from generic Eventstream APIs.

| Column | KQL type | Purpose |
|---|---|---|
| time | datetime | Event timestamp; reference as `['time']` in KQL |
| id | string | Envelope ID used for deduplication |
| type | string | Event type |
| data | dynamic | Operation fields |

Filter for `Microsoft.Fabric.CapacityOperationEvents.Operation`. See the
[query examples](monitoring/capacity-operations.kql) and
[documented event schema](https://learn.microsoft.com/en-us/fabric/real-time-hub/explore-fabric-capacity-operation-events).

```kusto
CapacityOperationEvents
| where ['time'] > ago(1h)
| where type == 'Microsoft.Fabric.CapacityOperationEvents.Operation'
| summarize EventRecords=count(), LastEventUtc=max(['time'])
  by CapacityId=tostring(data.capacityId)
```

Populate `collection.local.json` from your own deployments. No deployment receipt
or live environment ID is distributed in this repository. Script 11 reads exactly
two collections; use script 10 for one database.

## Interpretation

- CU Seconds: sum of `capacityUnitMs` / 1,000.
- Duration Seconds: sum of `durationMs` / 1,000, not CU and not elapsed wall time.
- Throttling Delay Seconds: sum of `throttlingDelayMs` / 1,000 for received events.
- Event Records: received rows, not necessarily distinct operations.
- Observed Operations: distinct capacity/operation-ID pairs, excluding blank IDs.
- Delayed Event Records: rows with positive delay; the current DAX count can be
  blank when no matching rows exist.

Blank operation IDs and missing operation-start timestamps occur in real records.
They are preserved rather than fabricated. Deduplicate using envelope IDs, not
operation IDs alone. Event timestamps, consumption windows and smoothing semantics
need separate qualification before claiming utilization parity with Capacity Metrics.

## Freshness and failure handling

Monitor the latest persisted event in each region and the report extraction
timestamp independently. A healthy Eventstream does not update the frozen report.

The model embeds selected operational records in its import partition. Refreshing
it does not call Kusto again. Script 11 creates a new model/report on every published
run; it is not an incremental refresh or update-in-place service.

Reconcile receipts and long-running-operation state after errors. Never retry
creation writes blindly. Missing data, partial results and overflow are failures,
not zeros. Do not induce throttling for demonstrations. Use the manual bounded
workload only with explicit authorization and stop its Spark session afterwards.

## PowerShell and Data Lake alternative

**Uploading files is feasible; an equivalent direct per-operation CU polling API
without an event consumer was not established by the reviewed documentation.**

| Option | Finding |
|---|---|
| Inventory APIs → PowerShell → Data Lake | Suitable for metadata inventory, not equivalent CU telemetry |
| Direct CU polling → PowerShell → Data Lake | Public equivalent source not established; do not promise it |
| Existing KQL → PowerShell export → Data Lake | Feasible archival design to develop; retains upstream Eventstream/Eventhouse |
| Capacity events → Eventstream → Lakehouse | Documented alternative without Eventhouse; retains Eventstream and requires a separate prototype |

The [source documentation](https://learn.microsoft.com/en-us/fabric/real-time-intelligence/event-streams/add-source-fabric-capacity-operation-events)
explicitly mentions routing to Lakehouse. The
[Lakehouse destination](https://learn.microsoft.com/en-us/fabric/real-time-intelligence/event-streams/add-destination-lakehouse)
stores Delta tables, has batching settings and schema-enforcement risks. New
columns may be excluded and incompatible records may be lost. Test schema changes,
startup routing, late events, duplicates and recovery. Scripts 10/11 currently read
Kusto; they cannot read Lakehouse automatically.

The [ADLS PowerShell file APIs](https://learn.microsoft.com/en-us/azure/storage/blobs/data-lake-storage-directory-file-acl-powershell)
and [OneLake API compatibility](https://learn.microsoft.com/en-us/fabric/onelake/onelake-access-api)
establish file-upload capability, not the availability of CU data. Uploading JSON to
Lakehouse `Files` does not create Delta tables or a Direct Lake-ready model.

An eventual batch exporter needs bounded windows, overlap for late events,
deduplication, durable checkpoints, integrity validation before checkpoint advance,
concurrency control, recovery, logging and source retention covering outages.
No such exporter, scheduler or additional lake deployment is included.

Do not extract the Capacity Metrics semantic model as a workaround: Microsoft
explicitly does not support external consumption of that model. Eventstream
definition APIs configure consumers; they are not raw event-download APIs.

Azure Monitor's catalog is not proof of universal absence of other metrics.
Read-only metric-definition checks on two Fabric F capacity resources during
development returned HTTP 400:

```text
Microsoft.Fabric/capacities is not a supported platform metric namespace
```

This finding applies to the tested resources, API route and date, not every future
capability. Do not substitute `Microsoft.PowerBIDedicated/capacities` metrics for
`Microsoft.Fabric/capacities` without explicit support.

## Costs and production work

No separate Azure Event Hubs resource is deployed by this POC. Eventstream,
Eventhouse and Azure Event Hubs are distinct products/components.

Evaluate Eventstream → Lakehouse if removing Eventhouse is the goal. Compare total
CU, storage, transactions, maintenance, job execution, report processing, latency
and data quality under representative workloads before claiming savings.
Lower monitoring CU can free headroom without lowering a fixed SKU's invoice.

For production, retain stable model/report identities and implement an approved
refresh/data-ingestion design, secure identities, audience isolation, retention,
residency, alerting and disaster recovery. No resources should be paused or deleted
on the assumption that uncaptured events can be retrieved later.
