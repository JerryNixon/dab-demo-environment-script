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

### Optional flags

```powershell
# Deploy new environment with custom parameters
./create.ps1 `
  -Region eastus `                                    # Customize the region (default: westus2)
  -DatabasePath ".\databases\database.sql" `          # Customize the database file (default: ./database.sql)
  -ConfigPath ".\configs\dab-config.json" `           # Customize the DAB configuration file (default: ./dab-config.json)
  -NoCleanup                                          # Don't roll back if there is a failure

# Customize individual resource names (new in v0.4.0)
./create.ps1 `
  -ResourceGroupName "my-dab-rg" `                    # Custom resource group name
  -SqlServerName "my-sql-server" `                    # Custom SQL Server name (will be lowercase)
  -SqlDatabaseName "my-database" `                    # Custom SQL Database name
  -ContainerAppName "my-api" `                        # Custom Container App name (will be lowercase)
  -AcrName "myregistry123" `                          # Custom ACR name (alphanumeric only, lowercase)
  -LogAnalyticsName "my-logs" `                       # Custom Log Analytics workspace name
  -ContainerEnvironmentName "my-aca-env"              # Custom Container App Environment name
```

### Resource naming rules

All resource names are automatically validated and sanitized according to Azure naming requirements. Names that don't meet these requirements are automatically corrected (converted to lowercase, invalid characters removed, truncated to max length, etc.).

- **Resource Group**: 1-90 chars, alphanumeric, hyphens, underscores, periods, parentheses allowed
- **SQL Server**: 1-63 chars, lowercase only, alphanumeric and hyphens, cannot start/end with hyphen
- **SQL Database**: 1-128 chars, most characters allowed
- **Container App**: 2-32 chars, lowercase only, alphanumeric and hyphens, no consecutive hyphens, cannot start/end with hyphen
- **Azure Container Registry**: 5-50 chars, lowercase alphanumeric only (hyphens and special chars stripped automatically)
- **Log Analytics**: 4-63 chars, alphanumeric and hyphens
- **Container Environment**: 1-60 chars, alphanumeric and hyphens

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

## Reference: create script summary

```sh
az group create \
  --name "$rg" \
  --location "$region" \
  --tags author=dab-demo version=0.4.0 owner="$owner"

az ad signed-in-user show \
  --query "{id:id,upn:userPrincipalName}"

az sql server create \
  --name "$sqlServer" \
  --resource-group "$rg" \
  --location "$region" \
  --enable-ad-only-auth \
  --external-admin-principal-type User \
  --external-admin-name "$currentUser" \
  --external-admin-sid "$userId"

az sql server update \
  --name "$sqlServer" \
  --resource-group "$rg" \
  --set tags.author=dab-demo tags.version=0.4.0 tags.owner="$owner"

az sql server show \
  --name "$sqlServer" \
  --resource-group "$rg" \
  --query fullyQualifiedDomainName

az sql server firewall-rule create \
  --resource-group "$rg" \
  --server "$sqlServer" \
  --name AllowAll \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 255.255.255.255

az sql server list-usages \
  --resource-group "$rg" \
  --name "$sqlServer" \
  --query "[?name.value=='FreeDatabaseCount']"

# free-tier path
az sql db create \
  --name "$sqlDb" \
  --server "$sqlServer" \
  --resource-group "$rg" \
  --tags author=dab-demo version=0.4.0 owner="$owner" \
  --use-free-limit true \
  --edition Free \
  --max-size 1GB \
  --query name \
  --output tsv

# fallback path
az sql db create \
  --name "$sqlDb" \
  --server "$sqlServer" \
  --resource-group "$rg" \
  --edition Basic \
  --service-objective Basic \
  --tags author=dab-demo version=0.4.0 owner="$owner"

sqlcmd -S "$sqlFqdn" -d "$sqlDb" -G -i "$databasePath"

dab validate --config "$configPath"

az monitor log-analytics workspace create \
  --resource-group "$rg" \
  --workspace-name "$logAnalytics" \
  --location "$region" \
  --tags author=dab-demo version=0.4.0 owner="$owner"

az monitor log-analytics workspace show \
  --resource-group "$rg" \
  --workspace-name "$logAnalytics" \
  --query customerId

az monitor log-analytics workspace get-shared-keys \
  --resource-group "$rg" \
  --workspace-name "$logAnalytics" \
  --query primarySharedKey

az monitor log-analytics workspace update \
  --resource-group "$rg" \
  --workspace-name "$logAnalytics" \
  --tags author=dab-demo version=0.4.0 owner="$owner" \
  --retention-time 90

az containerapp env create \
  --name "$acaEnv" \
  --resource-group "$rg" \
  --location "$region" \
  --logs-workspace-id "$customerId" \
  --logs-workspace-key "$workspaceKey" \
  --tags author=dab-demo version=0.4.0 owner="$owner"

az acr create \
  --resource-group "$rg" \
  --name "$acrName" \
  --sku Basic \
  --admin-enabled false \
  --tags author=dab-demo version=0.4.0 owner="$owner"

az acr show \
  --resource-group "$rg" \
  --name "$acrName" \
  --query loginServer

az acr build \
  --resource-group "$rg" \
  --registry "$acrName" \
  --image "$imageTag" \
  --file Dockerfile \
  --build-arg "DAB_VERSION=$dabVersion" \
  .

az containerapp create \
  --name "$container" \
  --resource-group "$rg" \
  --environment "$acaEnv" \
  --system-assigned \
  --ingress external \
  --target-port 5000 \
  --image mcr.microsoft.com/azuredocs/containerapps-helloworld:latest \
  --cpu 0.5 \
  --memory 1.0Gi \
  --env-vars MSSQL_CONNECTION_STRING="$conn" Runtime__ConfigFile=/App/dab-config.json \
  --tags author=dab-demo version=0.4.0 owner="$owner"

az containerapp show \
  --name "$container" \
  --resource-group "$rg" \
  --query identity.principalId

az acr show \
  --name "$acrName" \
  --resource-group "$rg" \
  --query id

az role assignment create \
  --assignee "$principalId" \
  --role AcrPull \
  --scope "$acrId"

az containerapp registry set \
  --name "$container" \
  --resource-group "$rg" \
  --server "$acrLogin" \
  --identity system

az containerapp update \
  --name "$container" \
  --resource-group "$rg" \
  --image "$imageTag" \
  --set-env-vars MSSQL_CONNECTION_STRING="$conn" Runtime__ConfigFile=/App/dab-config.json

az ad sp show \
  --id "$principalId" \
  --query displayName

sqlcmd -S "$sqlFqdn" -d "$sqlDb" -G -Q "CREATE USER [...]; ALTER ROLE db_datareader ADD MEMBER [...]; ALTER ROLE db_datawriter ADD MEMBER [...]; GRANT EXECUTE TO [...]"

sqlcmd -S "$sqlFqdn" -d "$sqlDb" -G -Q "<verification query>"

az containerapp revision list \
  --name "$container" \
  --resource-group "$rg" \
  --query "[0].name"

az containerapp revision restart \
  --name "$container" \
  --resource-group "$rg" \
  --revision "$revision"

az containerapp show \
  --name "$container" \
  --resource-group "$rg" \
  --query "{provisioning:properties.provisioningState,running:properties.runningStatus}"

az containerapp replica list \
  --name "$container" \
  --resource-group "$rg" \
  --query "[0].properties.containers[0].restartCount"

az containerapp show \
  --name "$container" \
  --resource-group "$rg" \
  --query properties.configuration.ingress.fqdn
```
