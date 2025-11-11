# Deploy Data API Builder to Azure Container Apps

Automated deployment of **Data API Builder (DAB)** on **Azure Container Apps (ACA)** using **Azure SQL Database** with **Entra ID authentication** and **baked-in configuration** via custom Docker image.

## Quick Start

### Initial Deployment

Ensure these files are in your working directory:

* `database.sql` - Your database schema
* `dab-config.json` - DAB configuration
* `Dockerfile` - Container image definition

Then run:

```powershell
.\script.ps1
```

### Update Existing Deployment

After modifying `dab-config.json`, update just the container image without redeploying infrastructure:

```powershell
.\script.ps1 -UpdateImage dab-demo-20251111113005
```

> **Fast Updates**: ~3 minutes vs ~8 minutes for full deployment  
> **Safe**: Only updates container image, doesn't touch database or other infrastructure

> Requires PowerShell 7+, Azure CLI, DAB CLI, and sqlcmd.

## What Gets Deployed

```
Resource Group: dab-demo-<timestamp>
 ├─ SQL Server
 │   └─ SQL Database
 ├─ Azure Container Registry
 ├─ Azure Log Analytics Workspace
 ├─ Azure Container Apps Environment
 │   └─ Container App (runs Data API builder)
```

### Resource tags

All resources are automatically tagged:

 - `author=dab-deploy-demo-script`
 - `owner=<your-username>`

## Prerequisites

* **PowerShell 5.1 or higher** (PowerShell 7+ recommended for best experience)
* **Azure CLI** - [Install](https://aka.ms/installazurecliwindows)
* **DAB CLI** - Required for configuration validation
* **sqlcmd** - Auto-installed via winget if available
* **Contributor** or **Owner** role on target subscription

> **Note**: The script is compatible with both PowerShell 5.1 and PowerShell 7+. However, PowerShell 7+ is recommended for improved performance and features.

## Three required external files

### `database.sql`
Your SQL schema and optional seed data. Executed using Entra ID authentication after database creation.

### `dab-config.json`
DAB configuration file **must** reference the connection string as:
```json
{
  "data-source": {
    "database-type": "mssql",
    "connection-string": "@env('MSSQL_CONNECTION_STRING')"
  }
}
```

### `Dockerfile`
(Provided) Builds a custom image with your config baked in. 

## Features

- **Fast updates**: Update container image in ~3 minutes with `-UpdateImage`
- Entra ID-only authentication (no SQL passwords)
- Managed identity for database and container registry access
- Automatic SQL permissions: db_datareader, db_datawriter, and EXECUTE (for stored procedures)
- Permission verification to ensure managed identity has all required SQL access
- Custom Docker image with config baked in (no secrets in environment variables)
- Free-tier database with automatic fallback to paid tier if unavailable
- Failed deployments auto-cleanup (or preserve with `-NoCleanup` for debugging)

## Updating Your Deployment

After making changes to `dab-config.json`, you can update just the container image without redeploying the entire infrastructure:

```powershell
# Update with default config location
.\script.ps1 -UpdateImage dab-demo-20251111113005

# Update with custom config location
.\script.ps1 -UpdateImage dab-demo-20251111113005 -ConfigPath .\configs\prod.json

# Skip confirmation prompt
.\script.ps1 -UpdateImage dab-demo-20251111113005 -Force
```

### How It Works

1. **Discovers existing resources** using tags (`author=dab-deploy-demo-script`)
2. **Generates config hash** to identify the new configuration
3. **Checks for existing image** - reuses if config hasn't changed
4. **Builds new image** with updated config in Azure Container Registry
5. **Updates container app** with new image tag
6. **Waits for rollout** - Azure Container Apps handles the rolling update
7. **Verifies health** - confirms new revision is responding

**What gets updated:**
- Container image with new DAB configuration

**What stays unchanged:**
- SQL Server and database
- Container Apps environment
- Azure Container Registry
- Log Analytics workspace
- All managed identities and permissions

**Time comparison:**
- Full deployment: ~8 minutes
- Image update: ~3 minutes

## Example Output

```sh
dab-deploy-demo version 0.0.1

Checking prerequisites...
  Azure CLI:   Installed (2.64.0)
  DAB CLI:     Installed (1.2.10)
  sqlcmd:      Installed
  database.sql: Found
  dab-config.json: Found
  Dockerfile:  Found
  Config hash: d3d294a8

Authenticating to Azure...
Azure authentication completed successfully

Current subscription:
  Name: Visual Studio Enterprise Subscription
  ID:   12345678-1234-1234-1234-123456789abc

Deploy to this subscription? (y/n/list) [y]

Starting deployment. Estimated time to complete: 8m (finish ~14:38:25)

Creating resource group
[Started] (est 3s at 14:30:25)
[Success] (dab-demo-20251107143022, 2.3s)

Getting current Azure AD user
[Started] (est 2s at 14:30:27)
[Success] (retrieved jerry@contoso.com)

Creating SQL Server
[Started] (est 80s at 14:32:47)
[Success] (sql-server-20251107143022, 78.4s)

Creating SQL database
[Started] (est 15s at 14:33:20)
[Success] (sql-database, Free-tier, 14.2s)

Deploying database schema
[Started] (est 30s at 14:33:50)
[Success] (schema deployed to sql-database, 4.2s)

Validating DAB configuration
[Started] (est 5s at 14:33:55)
[Success] (./dab-config.json validated, 1.6s)

Creating Log Analytics workspace
[Started] (est 42s at 14:34:37)
[Success] (log-workspace-20251107143022, 38.3s)

Creating Container Apps environment
[Started] (est 136s at 14:36:53)
[Success] (aca-environment-20251107143022, 134.2s)

Creating Azure Container Registry
[Started] (est 30s at 14:37:23)
[Success] (acr20251107143022, 29.4s)

Building custom DAB image with baked config
[Started] (est 90s at 14:38:53)
[Success] (acr20251107143022.azurecr.io/dab-baked:d3d294a8, 87.6s)

Creating Container App with managed identity
[Started] (est 60s at 14:39:53)
[Success] (data-api-container, 58.3s)

Assigning AcrPull role to managed identity
[Started] (est 15s at 14:40:08)
[Success] (AcrPull role assigned to data-api-container MI)

Retrieving managed identity display name
[Started] (est 3min at 14:43:08)
[Success] (Retrieved: data-api-container)

Granting managed identity access to SQL Database
[Started] (est 10s at 14:44:38)
[Success] (data-api-container granted access to sql-database, 45.2s)

Verifying SQL permissions
[Started] (est 3s at 14:45:23)
[Success] (Permissions verified: db_datareader, db_datawriter, EXECUTE, 2.1s)

Restarting container to activate managed identity
[Started] (est 15s at 14:45:26)
[Success] (data-api-container restarted, 12.4s)

Verifying container is running
[Started] (est 5min at 14:45:38)
[Success] (data-api-container running, restart count: 0)

Checking DAB API health endpoint
[Started] (est 1min at 14:50:38)
[Success] (DAB API health: Healthy)

==============================================================================
  DAB DEMO DEPLOYMENT SUMMARY
==============================================================================

RESOURCES
  Resource Group:    dab-demo-20251106143022
  Region:            westus2
  Total Time:        12.5m

  SQL Server:        sql-server-20251106143022
    Database:        sql-database (Free-tier)
    Admin:           jerry@contoso.com

  Container App:     data-api-container
    Environment:     aca-environment-20251106143022
    Identity:        System-assigned managed identity

  Log Analytics:     log-workspace-20251106143022

ENDPOINTS
  DAB API:          https://data-api-container...
  SQL Server:       sql-server-20251106143022.database.windows.net
  Portal RG:        https://portal.azure.com/...
  Portal SQL:       https://portal.azure.com/...
  Portal Container: https://portal.azure.com/...
  Portal Logs:      https://portal.azure.com/...
  Logs (CLI):       az containerapp logs show -n data-api-container -g dab-demo-20251106143022 --follow
```

## Script Parameters

### Deployment Mode

```powershell
.\script.ps1 [options]
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Region` | Azure region for deployment | `westus2` |
| `-DatabasePath` | Path to SQL database file | `./database.sql` |
| `-ConfigPath` | Path to DAB config file | `./dab-config.json` |
| `-Force` | Skip subscription confirmation | `false` |
| `-NoCleanup` | Preserve resources on failure (for debugging) | `false` |
| `-VerifyAdOnlyAuth` | Verify Azure AD-only auth is active (adds ~3min) | `false` |

**Examples:**
```powershell
# Default deployment
.\script.ps1

# Custom region
.\script.ps1 -Region eastus

# Custom paths
.\script.ps1 -DatabasePath .\db\schema.sql -ConfigPath .\config\prod.json

# Skip confirmation (for CI/CD)
.\script.ps1 -Force

# Keep resources on failure
.\script.ps1 -NoCleanup
```

### Update Mode

```powershell
.\script.ps1 -UpdateImage <resource-group-name> [options]
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-UpdateImage` | Resource group name of existing deployment | Required |
| `-ConfigPath` | Path to updated DAB config file | `./dab-config.json` |
| `-Force` | Skip subscription confirmation | `false` |

**Examples:**
```powershell
# Update with default config
.\script.ps1 -UpdateImage dab-demo-20251111113005

# Update with custom config
.\script.ps1 -UpdateImage dab-demo-20251111113005 -ConfigPath .\config\prod-v2.json

# Skip confirmation
.\script.ps1 -UpdateImage dab-demo-20251111113005 -Force
```

