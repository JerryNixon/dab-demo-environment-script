# Deploy Data API builder to Azure Container Apps

Automated deployment of **Data API builder (DAB)** on **Azure Container Apps (ACA)** using **Azure SQL Database** with **Entra ID (Azure AD)** authentication and **Azure File Share** for configuration storage.

## Quick Start

Ensure these files are in your working directory:

* `database.sql`
* `dab-config.json`

Then run:

```powershell
.\script.ps1
```

> Requires PowerShell 7+.

## Deploys the following resources

* **Azure SQL Database** (tries free tier, falls back to serverless GP)
* **Azure Storage Account + File Share** for config file
* **Azure Container App** running DAB with a **system-assigned managed identity**
* **SQL Server firewall rule** for your current public IP
* **Azure File mount** at `/mnt/dab-config/dab-config.json`
* **Log Analytics workspace** for ACA diagnostics
* **SQL roles (reader/writer)** for the managed identity
* **Unified tagging** – `author`, `version`, `owner` across all resources

## Prerequisites

* PowerShell 7+
* Azure CLI
* sqlcmd

### Required Permissions

* Azure **Contributor** role
* Entra ID rights to create managed identities

## Required Files

* `database.sql` – schema and optional seed data
* `dab-config.json` – DAB configuration (referencing `@env('MSSQL_CONNECTION_STRING')`)

## Wizard Overview

1. **Validates files** – Ensures `database.sql` and `dab-config.json` exist and are valid
2. **Confirms subscription** – Lists available subscriptions and switches context if needed
3. **Deploys** resources with real-time progress (docker-style inline updates)
4. **Outputs** a full deployment summary and optionally opens Azure Portal (skipped with `-NoBrowser`)

### Parameters

* **`Region`** — Azure region (default: `westus2`)
  Example: `-Region eastus`

* **`ContainerImage`** — Override the Data API builder container image (default: `mcr.microsoft.com/azure-databases/data-api-builder:1.7.75-rc`)
  Example: `-ContainerImage "mcr.microsoft.com/azure-databases/data-api-builder:latest"`

* **`DatabasePath`** — Local or relative path to SQL database file (default: `./database.sql`)
  Example: `-DatabasePath "C:\databases\prod.sql"`

* **`ConfigPath`** — Local or relative path to DAB configuration file (default: `./dab-config.json`)
  Example: `-ConfigPath "C:\configs\prod.json"`

* **`NoBrowser`** — Skips automatic launch of the Azure Portal after deployment
  Example: `-NoBrowser`

* **`Diagnostics`** — Enables detailed Azure CLI logging (sets `AZURE_CORE_ONLY_SHOW_ERRORS=0`, `AZURE_CLI_DIAGNOSTICS=1`)
  Example: `-Diagnostics`

Sample:

```powershell
.\script.ps1 -Region westeurope -DatabasePath .\prod.sql -ConfigPath .\dab-config.json -NoBrowser -Diagnostics
```

## Example Output

```text
Creating resource group                        [======================] dab-demo-20261104143022 (2.1s)
Creating Log Analytics workspace (1–2 min)     [======================] law-env-20261104143022 (22.3s)
Creating Container Apps environment (2–3 min)  [======================] aca-env-20261104143022 (83.2s)
Creating SQL Server (AAD-only)                 [======================] sql-server-20261104143022 (13.1s)
Creating SQL database                          [======================] sql-database (5.2s)
Creating storage account and file share        [======================] stgabc12320261104143022
Uploading dab-config.json                      [======================] Success
Creating container app (DAB)                   [======================] data-api-container (17.4s)
Granting MI access to SQL                      [======================] Success
Executing schema                               [======================] Success
```

## Advanced Configuration

Inside the script, the `$Config` hashtable supports:

| Setting               | Purpose                  | Default |
| --------------------- | ------------------------ | ------- |
| `SqlRetryAttempts`    | Managed identity retries | `3`     |
| `PropagationWaitSec`  | AAD propagation delay    | `30`    |
| `LogRetentionDays`    | Log Analytics retention  | `90`    |
| `ContainerCpu`        | CPU for ACA container    | `0.5`   |
| `ContainerMemory`     | Memory for ACA container | `1.0Gi` |
| `StorageShareQuotaGb` | File share quota         | `1GB`   |

Deployment summary is written to `dab-deploy-<timestamp>.json` in the current directory.

## Highlights

**Authentication**

* SQL Server created with Entra-only (`--enable-ad-only-auth`)
* Entra admin configured atomically at creation
* Managed identity granted `db_datareader` and `db_datawriter` roles

**Reliability**

* FQDN resolved from Azure metadata (multi-cloud safe)
* Free-tier check before DB creation
* Mount verification before container creation
* Retry with exponential backoff on upload and propagation

**Security**

* No SQL passwords ever stored
* Firewall rule limited to client IP
* Only least-privilege roles assigned
* Keys redacted from transcripts

**Cloud Coverage**

* Works across Azure Commercial, Government, China, and Germany
* Endpoint domain automatically resolved via `az sql server show`

