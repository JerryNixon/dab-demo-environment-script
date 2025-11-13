# Deploy Data API Builder to Azure

This project provides PowerShell scripts to deploy and manage Data API Builder (DAB) on Azure Container Apps with Azure SQL Database. Your `dab-config.json` is baked into the container image, so no secrets are stored in environment variables.

## Prerequisites

- PowerShell 5.1 or newer
- Azure CLI (logged in)
- Repo files in the working directory: `database.sql`, `dab-config.json`, `Dockerfile`

## Scripts

### create.ps1 - Deploy New Environment

Creates a complete new DAB environment from scratch (~8 minutes).

```powershell
# Deploy new environment
./create.ps1
```

The script will interactively:
- Prompt for Azure subscription selection
- Prompt for Azure region selection
- Create all necessary resources with a unique timestamp-based name

### update.ps1 - Update Existing Image

Updates the container image in an existing deployment with new configuration (~3 minutes).
The script will list available DAB resource groups and let you select one to update.

```powershell
# Update - interactive selection
./update.ps1

# Use custom config file
./update.ps1 -ConfigPath ./custom-config.json
```

Every update run pushes a fresh image tagged with the current timestamp, even when `dab-config.json` is unchanged.

### cleanup.ps1 - Delete Environments

Deletes DAB resource groups created by create.ps1.

```powershell
# Interactive selection (default)
./cleanup.ps1

# Dry run - see what would be deleted
./cleanup.ps1 -WhatIf

# Delete all without prompts
./cleanup.ps1 -Force
```

The cleanup script finds resource groups by the `author=dab-demo` tag and lets you select which ones to delete.

## What Gets Created

Each deployment creates:

- Resource group `dab-demo-<timestamp>`
- Azure SQL server + database (Free tier if available)
- Azure Container Registry
- Azure Container Apps environment + container app
- Log Analytics workspace

All resources are tagged with:
- `author=dab-demo` - Used to identify DAB deployments
- `owner=<username>` - Azure account username
- `timestamp=<timestamp>` - Creation timestamp
- `version=<script-version>` - Script version used

## Output

The create and update scripts end with a concise summary that lists:

- Total runtime
- Resource names and identifiers
- Image tag (timestamp-based)
- API endpoint URLs (Swagger, GraphQL, health)

Azure validates regions and other constraints at runtime.


