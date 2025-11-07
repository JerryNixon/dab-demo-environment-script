# Deploy Data API Builder to Azure Container Apps

Automated deployment of **Data API Builder (DAB)** on **Azure Container Apps (ACA)** using **Azure SQL Database** with **Entra ID authentication** and **baked-in configuration** via custom Docker image.

**Version 0.0.1** | **Optimized for security, reliability, and simplicity**

## Quick Start

Ensure these files are in your working directory:

* `database.sql` - Your database schema
* `dab-config.json` - DAB configuration
* `Dockerfile` - Container image definition

Then run:

```powershell
.\script.ps1
```

> Requires PowerShell 7+, Azure CLI, DAB CLI, and sqlcmd.

## What Gets Deployed

* **Azure SQL Database** (tries free tier with fallback to Basic paid tier) with **Entra ID-only authentication**
* **Azure Container Registry** (ACR Basic) with **managed identity authentication** (no anonymous pull)
* **Azure Container App** running DAB with **system-assigned managed identity** and **registry-identity authentication**
* **SQL Server firewall rule** (allows all IPs: 0.0.0.0-255.255.255.255 for demo purposes)
* **Log Analytics workspace** for container diagnostics (90-day retention)
* **AcrPull role assignment** for managed identity with propagation verification
* **SQL roles (reader/writer)** with **TRY/CATCH error handling** and **exponential backoff retry** (12 attempts, up to 240s)
* **Custom Docker image** with `dab-config.json` baked in
* **DAB health check verification** (5 attempts, 10s intervals)

All resources tagged with: `author=dab-deploy-demo-script`, `version=<script-version>`, `owner=<your-username>`

## Prerequisites

### Required Software
* **PowerShell 7+** (not Windows PowerShell 5.1)
* **Azure CLI** - [Install](https://aka.ms/installazurecliwindows)
* **DAB CLI** - Required for configuration validation
* **sqlcmd** - Auto-installed via winget if available

### Required Permissions
* Azure **Contributor** or **Owner** role on target subscription
* Permissions validated at script startup (fails fast if insufficient)

## Required Files

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

The script validates this before deployment and runs a pre-deployment validation job to catch configuration errors early.

### `Dockerfile`
Builds a custom image with your config baked in. Uses the official DAB base image. Container Apps provides platform-level health probes via TCP port checks, so Docker HEALTHCHECK directives are not needed.

## Deployment Flow

1. **Prerequisites Check** - Validates Azure CLI, DAB CLI, sqlcmd, required files
2. **Azure Login** - Ensures correct subscription context
3. **Tenant & Subscription Pinning** - Captures IDs for explicit scoping (multi-tenant safety)
4. **Resource Group Creation** - Creates timestamped resource group
5. **Entra ID User Lookup** - Gets current user for SQL admin
6. **SQL Server Creation** - Creates with Entra-only authentication
7. **Firewall Configuration** - Adds 0.0.0.0-255.255.255.255 (demo-friendly, not production)
8. **Entra ID Authentication Verification** - Exponential backoff (10 attempts, 1.7x multiplier, 120s cap)
9. **Free-Tier Capacity Check** - Checks if free database is available
10. **SQL Database Creation** - Creates free-tier or Basic paid database
11. **Database Schema Deployment** - Executes `database.sql` with error logging
12. **DAB Config Validation** - Validates configuration using DAB CLI
13. **Log Analytics Workspace** - Creates with 90-day retention
14. **Container Apps Environment** - Provisions ACA environment (2-3 minutes)
15. **Azure Container Registry** - Creates ACR Premium with admin disabled
16. **Custom Image Build** - Builds DAB image with config baked in (via ACR build task)
17. **Container App Creation** - Single-step creation with ACR image, MI, and env vars
18. **AcrPull Role Assignment** - Grants ACR pull permission to managed identity
19. **Service Principal Lookup** - Gets MI display name using `az ad sp show` (exponential backoff, 20 attempts)
20. **SQL Access Grant** - Grants MI database permissions with T-SQL TRY/CATCH (12 attempts, exponential backoff)
21. **Container Restart** - Activates managed identity authentication
22. **Container Running Verification** - Confirms container is active (crash loop detection)
23. **DAB Health Check** - Verifies API responding (5 attempts, 10s intervals)
24. **Deployment Summary** - Outputs complete resource details and URLs
25. **Portal Launch** - Opens Azure Portal (unless -NoBrowser specified)

## Parameters

### `-Region` (string)
Azure region for deployment. Default: `westus2`

Supported regions validated at startup.

```powershell
.\script.ps1 -Region eastus
```

### `-Force` (switch)
Skips subscription confirmation prompt. Useful for CI/CD pipelines and automation.

```powershell
.\script.ps1 -Force
```

### `-DatabasePath` (string)
Path to SQL database file. Default: `./database.sql`

```powershell
.\script.ps1 -DatabasePath "C:\databases\prod.sql"
```

### `-ConfigPath` (string)
Path to DAB configuration file. Default: `./dab-config.json`

```powershell
.\script.ps1 -ConfigPath "C:\configs\prod-config.json"
```

### `-NoBrowser` (switch)
Skips automatic Azure Portal launch after deployment. Useful for CI/CD.

```powershell
.\script.ps1 -NoBrowser
```

### `-NoCleanup` (switch)
Preserves resource group on deployment failure for debugging. Default behavior deletes failed deployments automatically.

```powershell
.\script.ps1 -NoCleanup
```



## Example Usage

### Basic Deployment
```powershell
.\script.ps1
```

### Production Deployment (Different Region)
```powershell
.\script.ps1 -Region eastus -DatabasePath .\prod-schema.sql -ConfigPath .\prod-config.json
```

### CI/CD Deployment (Non-interactive)
```powershell
.\script.ps1 -Force -NoBrowser
```

### Debug Failed Deployment
```powershell
.\script.ps1 -NoCleanup
```

## Example Output

The script provides real-time progress with **estimated duration** and **ETA timestamps** for each deployment step:

```
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

Creating resource group
[Started] (est 3s at 14:30:25)
[Success] (dab-demo-20251107143022, 2.3s)

Getting current Azure AD user
[Started] (est 2s at 14:30:27)
[Success] (retrieved jerry@contoso.com)

Creating SQL Server
[Started] (est 80s at 14:32:47)
[Success] (sql-server-20251107143022, 78.4s)

Verifying Entra ID authentication
[Started] (est 3min at 14:33:05)
[Success] (active)

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
[Started] (est 90s at 14:44:38)
[Success] (data-api-container granted access to sql-database, 45.2s)

Restarting container to activate managed identity
[Started] (est 15s at 14:44:53)
[Success] (data-api-container restarted, 12.4s)

Verifying container is running
[Started] (est 5min at 14:49:53)
[Success] (data-api-container running, restart count: 0)

Checking DAB API health endpoint
[Started] (est 1min at 14:50:53)
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

Opening Azure Portal...
```

## Features

### Recent Improvements (v0.0.1)

**Security Enhancements:**
- ✅ **Disabled ACR anonymous pull** - Uses managed identity with AcrPull role assignment
- ✅ **Added --registry-identity system** - Container App pulls images using its managed identity
- ✅ **T-SQL TRY/CATCH blocks** - SQL user grant operations have proper error handling

**Reliability Improvements:**
- ✅ **Single-step Container App creation** - Eliminates "public image then swap" workaround
- ✅ **Exponential backoff for Entra ID** - 1.7x multiplier, 120s cap (was fixed 30s waits)
- ✅ **Simplified MI lookup** - Uses only `az ad sp show` (removed Graph API fallback)
- ✅ **Tenant & subscription pinning** - Explicit IDs prevent multi-tenant context issues

**Code Quality:**
- ✅ **Consolidated logging** - Single `cli.log` with [OK] and [ERR] tags (was separate out/err files)
- ✅ **Optional cleanup** - `-NoCleanup` switch preserves failed deployments for debugging
- ✅ **Resource names in success messages** - "sql-server-20251107... (78.4s)" instead of just timing
- ✅ **Removed Test-NetConnection** - Windows-specific, non-essential check eliminated

### Core Features

**Timing & Race Condition Handling:**
- **Entra ID propagation** - Exponential backoff retry (10 attempts, 1.7x multiplier, 120s cap)
- **SQL MI propagation retry** - 12 attempts with exponential backoff and jitter (up to 240s)
- **Service Principal lookup** - 20 attempts with exponential backoff (1.8x multiplier)
- **DAB health check retries** - 5 attempts, 10s intervals
- **Free-tier capacity check** - Automatic fallback to Basic paid tier

**Security:**
- Entra ID-only authentication (no SQL passwords)
- Managed identity with least-privilege database roles
- ACR authentication via managed identity (no admin credentials)
- Firewall configured for all IPs (demo-friendly; customize for production)

**Observability:**
- Real-time progress tracking with resource names in success messages
- Consolidated logging to single timestamped `cli.log` file ([OK]/[ERR] tags)
- Container Apps logs integrated with Log Analytics (90-day retention)
- Success banner on completion

**Error Recovery:**
- Exponential backoff retry logic for transient failures
- Graceful degradation (free tier fallback, optional DAB validation)
- Detailed error messages with remediation steps
- Optional cleanup preservation via `-NoCleanup` for debugging

## Script Architecture

### Helper Functions
- `Wait-Seconds` - Consistent wait operations with status output
- `Write-StepStatus` - Standardized progress reporting (Started/Success/Error/Retrying/Info)
- `OK` - Terse error checking (`OK $result "error message"`)
- `Test-AzureTokenExpiry` - Azure token validation and refresh
- `Get-MI-DisplayName` - Managed identity service principal lookup with exponential backoff
- `Invoke-AzCli` - Azure CLI wrapper with consolidated logging ([OK]/[ERR] tags)
- `Write-DeploymentSummary` - Formatted deployment summary output
- `Assert-ResourceNameLength` - Validates Azure resource name lengths

### Key Configuration Variables
- `$Config.SqlRetryAttempts` - 12 attempts for SQL user grant
- `$Config.LogRetentionDays` - 90 days for Log Analytics
- `$Config.ContainerCpu` - 0.5 CPU cores
- `$Config.ContainerMemory` - 1.0Gi RAM

### Logging Strategy
All Azure CLI commands logged to single `cli.log` file with:
- Timestamp (ISO 8601)
- Status tag ([OK] or [ERR])
- Full command line
- Complete output

Location: `logs\<timestamp>\cli.log`