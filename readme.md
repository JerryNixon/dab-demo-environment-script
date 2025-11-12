# Deploy Data API Builder to Azure

This script provisions everything needed to run Data API Builder (DAB) on Azure Container Apps with Azure SQL Database. Your `dab-config.json` is baked into the container image, so no secrets are stored in environment variables.

## Prerequisites

- PowerShell 5.1 or newer
- Azure CLI (logged in)
- Data API Builder CLI (`dab`)
- `sqlcmd`
- Repo files in the working directory: `database.sql`, `dab-config.json`, `Dockerfile`

## Deploy

```powershell
# Full environment (~8 minutes)
./create.ps1
```

## Update Only the Image

```powershell
# Use the resource group created during deploy (~3 minutes)
./create.ps1 -UpdateImage <resource-group-name>
```

Every update run pushes a fresh image tagged with the current timestamp, even when `dab-config.json` is unchanged.

## What Gets Created

- Resource group `dab-demo-<timestamp>`
- Azure SQL server + database (Free tier if available)
- Azure Container Registry
- Azure Container Apps environment + container app
- Log Analytics workspace

## Output

Both deploy modes end with a concise summary that lists:

- Total runtime
- Resource group and container names
- Image tag (timestamp-based)
- Swagger, GraphQL, and health URLs

Azure validates regions and other constraints at runtime, and the update flow always preserves existing resources.


