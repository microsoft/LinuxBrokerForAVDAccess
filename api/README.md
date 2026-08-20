# Broker API

This folder contains the Flask **Broker API** for the Linux Broker for AVD Access solution. It is the control-plane service used by the Service Management Portal, the scheduled scaling task, the AVD host broker, and the Linux host agents. For the full solution architecture and deployment model, see the repository [README](../README.md).

## Purpose

The API brokers Linux host checkouts, records VM state in Azure SQL, manages scaling rules, triggers scaling actions, and delivers the fleet-wide Linux host settings profile. It does not own the database schema; schema and stored procedure changes belong under the [`sql_queries`](../sql_queries/README.md) folder.

## Endpoint Reference

`token_required(...)` grants access when the bearer token has any listed delegated scope or app role. When a group is listed, membership in that configured group also grants access.

| Method | Path | Required scopes, roles, or groups | Description |
| --- | --- | --- | --- |
| GET | `/health` | none | Checks database connectivity and returns API health and version. |
| GET | `/api/version` | none | Returns the API version string. |
| GET | `/api/vms` | `access_as_user`, `FullAccess`, `ScheduledTask` | Lists all broker VM records. |
| GET | `/api/vms/summary` | `access_as_user`, `FullAccess`, `ScheduledTask` | Returns dashboard counters: `TotalVMs`, `Available`, `CheckedOut`, `Maintenance`, `Released`, `PoweredOn`, `PoweredOff`, `Unreachable`, and `Ready`. |
| POST | `/api/vms/checkout` | `AvdHost`, `access_as_user`, `FullAccess`, or `AVD_HOST_GROUP_ID` membership | Checks out a ready Linux host and creates or updates the remote user. |
| POST | `/api/vms/<vmid>/update-attributes` | `ScheduledTask`, `access_as_user`, `FullAccess` | Updates VM power, network, or broker status fields. |
| POST | `/api/vms/<vmid>/delete` | `access_as_user`, `FullAccess` | Deletes a VM record. |
| POST | `/api/vms/add` | `access_as_user`, `FullAccess` | Adds a VM record. |
| GET | `/api/vms/<vmid>` | `access_as_user`, `FullAccess` | Gets one VM record. |
| POST | `/api/vms/<vmid>/return` | `access_as_user`, `FullAccess` | Returns a checked-out VM and removes the remote user when possible. |
| POST | `/api/vms/<hostname>/release` | `LinuxHost`, `access_as_user`, `FullAccess`, or `LINUX_HOST_GROUP_ID` membership | Marks a host-side session released, with optional `username` and `leaseId` validation. |
| POST | `/api/vms/released` | `ScheduledTask`, `access_as_user`, `FullAccess` | Returns expired released VMs to the available pool and removes remote users. |
| POST | `/api/vms/history` | `access_as_user`, `FullAccess` | Returns VM history, optionally paged with `page` and `per_page`. |
| POST | `/api/scaling/log` | `access_as_user`, `FullAccess` | Returns scaling activity history, optionally paged with `page` and `per_page`. |
| POST | `/api/scaling/trigger` | `ScheduledTask`, `access_as_user`, `FullAccess` | Runs scaling logic and starts or stops Azure VMs as directed by SQL. |
| GET | `/api/scaling/rules` | `access_as_user`, `FullAccess` | Lists scaling rules; an empty rule set is `[]` with `200`. |
| GET | `/api/scaling/rules/<int:ruleid>` | `access_as_user`, `FullAccess` | Gets one scaling rule. |
| POST | `/api/scaling/rules/create` | `access_as_user`, `FullAccess` | Creates a scaling rule. |
| POST | `/api/scaling/rules/<int:ruleid>/update` | `access_as_user`, `FullAccess` | Updates a scaling rule. |
| POST | `/api/scaling/rules/<int:ruleid>/delete` | `access_as_user`, `FullAccess` | Deletes a scaling rule. |
| POST | `/api/scaling/rules/history` | `access_as_user`, `FullAccess` | Returns scaling rule history, optionally paged with `page` and `per_page`. |
| GET | `/api/hosts/settings` | `LinuxHost`, `access_as_user`, `FullAccess`, `ScheduledTask`, or `LINUX_HOST_GROUP_ID` membership | Returns the fleet-wide Linux host settings profile. |
| POST | `/api/hosts/settings/update` | `access_as_user`, `FullAccess` | Updates the fleet-wide Linux host settings profile. |
| POST | `/api/hosts/settings/apply` | `access_as_user`, `FullAccess`, `ScheduledTask` | Pushes the current settings profile to reachable hosts over SSH. |
| POST | `/api/hosts/<hostname>/settings/ack` | `LinuxHost`, `access_as_user`, `FullAccess`, or `LINUX_HOST_GROUP_ID` membership | Records the settings version applied by one host. |

`/api/vms/available` is not present in `app.py`; do not add new callers for it.

## Consumers

These callers constrain response shapes and endpoint compatibility.

| Consumer | Endpoints |
| --- | --- |
| `front_end` portal | VM, scaling, and host-settings endpoints. The dashboard prefers `/api/vms/summary`; history pages request `page` and `per_page`. |
| `task\function_app.py` | `/api/vms`, `/api/vms/released`, `/api/vms/<vmid>/update-attributes`, `/api/scaling/trigger` |
| Linux host release agent (`linux_host\...\release-session.sh`) | `/api/vms/<hostname>/release` |
| AVD host (`avd_host\...\Connect-LinuxBroker.ps1`) | `/api/vms/checkout` |
| Linux host settings agent | `/api/hosts/settings`, `/api/hosts/<hostname>/settings/ack` |

## Authentication and Authorization

Clients send Entra ID bearer tokens in the HTTP `Authorization` header. `token_required()` validates the token signature against the tenant JWKS, accepts audiences `CLIENT_ID` and `api://<CLIENT_ID>`, and accepts issuers:

- `{AUTHORITY_HOST}/{TENANT_ID}/v2.0`
- `{AUTHORITY_HOST}/{TENANT_ID}/`
- `{STS_ISSUER_HOST}/{TENANT_ID}/`

Authorization then checks delegated scopes in `scp`, app roles in `roles`, and optional group membership through Microsoft Graph `checkMemberGroups` using the token `oid`.

Cloud endpoints are resolved in [`config.py`](config.py). `AZURE_CLOUD_NAME=AzurePublic` uses `login.microsoftonline.com`, `graph.microsoft.com`, and `sts.windows.net`. `AzureUSGovernment` uses `login.microsoftonline.us` and `graph.microsoft.us`. Any custom or sovereign cloud without a built-in profile must set `AZURE_AUTHORITY_HOST`, `GRAPH_ENDPOINT`, and `STS_ISSUER_HOST` explicitly.

## Error Responses and Logging

Handler failures use a JSON error envelope:

```json
{"error": "Unable to retrieve virtual machines."}
```

Exception detail must not be returned in the response body. Log details with the `linuxbroker.api` logger; when `APPLICATIONINSIGHTS_CONNECTION_STRING` is set, that logger is configured for Azure Monitor. Authentication middleware and `/health` have their own fixed response shapes, but application handler errors should use the envelope.

## Pagination Contract

`/api/vms/history`, `/api/scaling/log`, and `/api/scaling/rules/history` support opt-in pagination. Supplying either `page` or `per_page` in the query string returns an envelope:

```http
POST /api/vms/history?page=2&per_page=25
Content-Type: application/json

{"startdate":"08/01/2026","enddate":"08/19/2026"}
```

```json
{
  "items": [
    {"VMID": 42, "Hostname": "linux-01"}
  ],
  "page": 2,
  "per_page": 25,
  "total": 91,
  "total_pages": 4
}
```

When neither `page` nor `per_page` is present, the response remains a bare JSON array. Do not remove that default: `task\function_app.py` and older portal builds consume these endpoints as plain lists. The unpaged path also deliberately tolerates `"null"` for `limit`; older portal builds sent that sentinel for **No Limit**, and rolling deployments must not turn it into a SQL `INT` conversion failure.

Empty collection responses are arrays with `200`, including `/api/scaling/rules`, `/api/scaling/log`, and `/api/scaling/rules/history`.

## VM Summary

`GET /api/vms/summary` returns fixed-size dashboard counters instead of requiring the portal to fetch every VM. `Ready` uses the same condition as checkout host selection: `VmStatus='Available'`, `PowerState='On'`, and `NetworkStatus='Reachable'`.

## Configuration

The API reads environment variables directly; it does not load `.env` files by itself. [`env.example`](env.example) shows the deployment settings.

| Variable | Required | Purpose |
| --- | --- | --- |
| `SCM_DO_BUILD_DURING_DEPLOYMENT` | deployment | Enables App Service build during deployment. |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | optional | Enables Azure Monitor/OpenTelemetry export for `linuxbroker.api`. |
| `ApplicationInsightsAgent_EXTENSION_VERSION` | optional | App Service Application Insights extension version. |
| `APPLICATIONINSIGHTSAGENT_EXTENSION_ENABLED` | optional | Enables the App Service Application Insights extension. |
| `WEBSITE_HTTPLOGGING_RETENTION_DAYS` | optional | App Service HTTP log retention. |
| `VM_SUBSCRIPTION_ID` | required for scaling | Azure subscription used by `/api/scaling/trigger`. |
| `VM_RESOURCE_GROUP` | required for scaling | Resource group containing Linux host VMs. |
| `AVD_HOST_GROUP_ID` | required for AVD host group auth | Entra group whose members may call checkout. |
| `LINUX_HOST_GROUP_ID` | required for Linux host group auth | Entra group whose members may call release and host-settings ack/read endpoints. |
| `LINUX_HOST_ADMIN_LOGIN_NAME` | optional | SSH admin user prefix for remote host commands; defaults to `avdadmin`. |
| `DB_SERVER` | required | Azure SQL Server name or FQDN for `pymssql`. |
| `DB_DATABASE` | required | Azure SQL database name. |
| `DB_USERNAME` | required | SQL login name. |
| `DB_PASSWORD_NAME` | required | Key Vault secret name containing the SQL password. |
| `CLIENT_ID` | required | Broker API app registration client ID and accepted token audience. |
| `TENANT_ID` | required | Entra tenant used for token validation and Graph calls. |
| `AZURE_CLOUD_NAME` | optional | Cloud profile name; defaults to `AzurePublic`. |
| `AZURE_AUTHORITY_HOST` | required for `AzureCustom` | Login authority host override. |
| `GRAPH_ENDPOINT` | required for `AzureCustom` | Microsoft Graph endpoint override. |
| `STS_ISSUER_HOST` | required for `AzureCustom` | STS issuer host override. |
| `GRAPH_API_ENDPOINT` | optional | Legacy Graph scope setting in `config.py`; current token acquisition uses `GRAPH_ENDPOINT`. |
| `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` | required | Client secret used by the API to call Graph for group checks. |
| `DOMAIN_NAME` | required for SSH actions | DNS suffix used to build `<admin>@<hostname>.<domain>`. |
| `VAULT_URL` | required | Key Vault URL for SQL password and SSH key retrieval. |
| `KEY_NAME` | required for SSH actions | Key Vault secret name containing the PEM SSH private key. |
| `NFS_SHARE` | required for checkout provisioning | NFS share argument passed to `create-user.sh`; used by code but not currently listed in `env.example`. |

## Database Access

Handlers call stored procedures rather than embedding schema logic in Python. `db_connection()` wraps `get_db_connection()` as a context manager so every acquired connection is closed on success or exception.

Keep schema and procedure changes in numbered files under [`sql_queries`](../sql_queries/README.md). The deployment bootstrap applies those scripts in filename order and rewrites procedures to `CREATE OR ALTER PROCEDURE` for reruns.

## Local Development and Tests

Install runtime dependencies from this folder:

```powershell
cd .\api
py -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python .\app.py
```

Set the required environment variables first. For local test runs, install the dev requirements and run pytest from the `api` folder:

```powershell
pip install -r requirements.txt -r requirements-dev.txt
pytest
```

`api\tests\` contains pytest regression coverage for the hardened API paths, including connection cleanup, error envelopes, empty collections, VM summary, and paged history responses.
