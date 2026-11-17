# Identities and least privilege

Keep provisioning, collection ownership, reporting and viewing separate.
Successful calls with an administrative user do not prove minimum privileges.

## Workspace provisioning

A dedicated service principal can create workspaces without becoming a Fabric
Administrator or Global Administrator at runtime.

A tenant administrator configures the relevant settings once, scoped to a dedicated
security group containing the automation identity:

- **Service principals can create workspaces, connections, and deployment pipelines**.
- **Service principals can call Fabric public APIs** for subsequent protected API calls.

Check workspace creation policy and group propagation. A tenant-setting group is
not a capacity role, workspace role or OAuth application permission.

| Action | Required access |
|---|---|
| Create workspace | Tenant-authorized creation identity; target Capacity Contributor/Admin if assigned at creation |
| Assign existing workspace | Workspace Admin **and** target Capacity Contributor/Admin |
| Add Workspace Admin | Workspace Admin |
| Add Member/Contributor/Viewer | Workspace Member/Admin per operation; Member cannot add Admin |
| Delete demo workspace | Workspace Admin plus this script's ownership receipt checks |

Capacity Contributor is sufficient for capacity assignment; do not grant Capacity
Admin just for workspace provisioning. The creator's Workspace Admin role is read
back by script 03. Use explicit Entra **object IDs** for user/group role grants.

No Azure subscription Owner/Contributor is required for these Fabric-only runtime
operations. Azure RBAC, Capacity Contributor and Workspace Contributor are different
authorization systems.

## Collection

- Workspace Contributor+ to create Eventstream/Eventhouse items.
- **Capacity Admin retained on the source** for the lifetime of the capacity event
  subscription.
- Same-region source/consumer placement for capacity operation events.

Temporary elevation followed by removal is not a supported way to keep the listener
running. App-only source configuration and ownership must be validated for the
chosen identity and item APIs; this POC does not implement that deployment.

## Reporting

- KQL database Viewer for ordinary-table reads; this is database-wide access,
  not per-workspace isolation of rows inside the telemetry.
- Contributor+ for Fabric model/report creation, per those item APIs.
- Model write/processing permissions for Power BI refresh. The service-principal
  guidance used for this combined POC path recommends Member on a dedicated
  destination workspace; do not claim the minimum app-only role has been proven.
- Report access plus applicable licensing for viewers. Test using a separate
  non-administrative identity.

No source Capacity Admin is required merely to read copied data with Kusto Viewer.
Report filters are not a security boundary. The POC does not provision RLS.

## Authentication

Script 11 explicitly supports `-DelegatedUser` for an interactive Azure CLI login.
By default, helpers reject delegated tokens and verify tenant/application identity.
Obtaining a token does not grant authorization.

| Service | Token resource |
|---|---|
| Fabric | https://api.fabric.microsoft.com |
| Kusto | https://api.kusto.windows.net |
| Power BI | https://analysis.windows.net/powerbi/api |

Delegated scopes such as `Workspace.ReadWrite.All` must not be added as if they were
application permissions to bypass an app-only 403. Validate each API's identity
support, tenant setting and item permissions.

Use protected certificates, managed identities or workload identity federation
where supported. Never distribute a service identity's private key or token to users.
The Azure CLI maintains its own token cache; keep it outside shared/synced source
folders, and avoid debug logging or transcripts containing authentication material.

## Potential lake exporter

For ADLS Gen2 writes, configure appropriate data-plane RBAC and/or path ACLs and
network access. For OneLake writes, use Fabric/OneLake authorization and a
Storage-audience token. Neither is granted by the workspace-creation tenant setting.
No lake exporter is implemented here.

## References

- [Developer tenant settings](https://learn.microsoft.com/en-us/fabric/admin/service-admin-portal-developer)
- [Create workspace](https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/create-workspace)
- [Assign to capacity](https://learn.microsoft.com/en-us/rest/api/fabric/core/workspaces/assign-to-capacity)
- [Event subscription permissions](https://learn.microsoft.com/en-us/fabric/real-time-hub/fabric-events-subscribe-permission)
- [Fabric delegated scopes](https://learn.microsoft.com/en-us/rest/api/fabric/articles/scopes)
- [Kusto database security roles](https://learn.microsoft.com/en-us/kusto/management/manage-database-security-roles?view=microsoft-fabric)
- [Power BI service principal guidance](https://learn.microsoft.com/en-us/power-bi/developer/embedded/embed-service-principal)
