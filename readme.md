# Deploy Data API Builder to Azure

PowerShell scripts to deploy and manage Data API Builder (DAB) on Azure Container Apps with Azure SQL Database. Your `dab-config.json` is baked into the container image, so no secrets are stored in environment variables.

### Prerequisites

- PowerShell [Install](https://aka.ms/powershell)
- Azure CLI [Install](http://aka.ms/azcli)
- SQLCMD [Install](http://aka.ms/sqlcmd)

## create.ps1 - Deploy New Environment

Creates a complete new DAB environment from scratch. The current user will need an Azure subscription as well as authority to create. 

```powershell
# Deploy new environment
./create.ps1

# (optional) Customize the region
.\create.ps1 -Region eastus

# (optional) Customize the database file
.\create.ps1 -DatabasePath ".\databases\database.sql" 

# (optional) Customize the DAB configuration file
.\create.ps1 -ConfigPath ".\configs\dab-config.json"

# (optional) Customize the Resource names prefix
.\create.ps1 -ResourePrefix  

# (optional) Don't roll back if there is a failure
.\create.ps1 -NoCleanup  
```

### Resources created

```
Resource Group: dab-demo-<timestamp>
 ├─ SQL Server
 │   └─ SQL Database
 ├─ Azure Container Registry
 ├─ Azure Log Analytics Workspace
 ├─ Azure Container Apps Environment
 │   └─ Container App (runs Data API builder)
 ```

 ### Tags used

- `author=dab-demo` - Used to identify DAB deployments
- `owner=<username>` - Azure account username
- `version=<script-version>` - Script version used

## update.ps1 - Update Existing Image

Updates the container image in an existing deployment with new configuration. Every update run pushes a fresh image tagged with the current timestamp, even when `dab-config.json` is unchanged.

```powershell
# Update - interactive selection
./update.ps1

# Use custom config file
./update.ps1 -ConfigPath ./custom-config.json
```

## cleanup.ps1 - Delete Environments

Deletes DAB resource groups created by create.ps1. The cleanup script finds resource groups by the `author=dab-demo` tag and lets you select which ones to delete.

```powershell
# Interactive selection (default)
./cleanup.ps1

# Dry run - see what would be deleted
./cleanup.ps1 -WhatIf

# Delete all without prompts
./cleanup.ps1 -Force
```

