# Deploy Data API Builder with Azure SQL Database and Container Apps
# 
# Parameters:
#   -Region: Azure region for deployment (default: westus2)
#   -DatabasePath: Path to SQL database file - local or relative from script root (default: ./database.sql)
#   -ConfigPath: Path to DAB config file - used to build custom image (default: ./dab-config.json)
#   -Force: Skip subscription confirmation prompt (useful for CI/CD automation)
#   -NoCleanup: Preserve resource group on failure for debugging (default: auto-cleanup)
#   -VerifyAdOnlyAuth: Verify Azure AD-only authentication is active (adds ~3min wait, optional)
#   -UpdateImage: Update existing deployment with new DAB config (specify resource group name)
#
# Notes:
#   The script builds a custom Docker image with dab-config.json baked in using Azure Container Registry.
#   The Dockerfile must be present in the current directory.
#
# Examples:
#   .\script.ps1
#   .\script.ps1 -Region eastus
#   .\script.ps1 -Region westeurope -DatabasePath ".\databases\prod.sql" -ConfigPath ".\configs\prod.json"
#   .\script.ps1 -Force      # Skip confirmation prompts
#   .\script.ps1 -NoCleanup  # Keep resources on failure for debugging
#   .\script.ps1 -VerifyAdOnlyAuth  # Verify AD-only auth propagation (slower but more thorough)
#   .\script.ps1 -UpdateImage dab-demo-20251111113005  # Update existing deployment
#
param(
    [Parameter(ParameterSetName='Deploy')]
    [string]$Region = "westus2",
    
    [Parameter(ParameterSetName='Deploy')]
    [string]$DatabasePath = "./database.sql",
    
    [string]$ConfigPath = "./dab-config.json",
    
    [switch]$Force,
    
    [Parameter(ParameterSetName='Deploy')]
    [switch]$NoCleanup,
    
    [Parameter(ParameterSetName='Deploy')]
    [switch]$VerifyAdOnlyAuth,
    
    [Parameter(ParameterSetName='UpdateImage', Mandatory)]
    [string]$UpdateImage
)

$Version = "0.1.4"

Set-StrictMode -Version Latest

$validRegions = @("eastus", "eastus2", "westus", "westus2", "westus3", "centralus", "northcentralus", "southcentralus", "westcentralus", "canadacentral", "canadaeast", "brazilsouth", "northeurope", "westeurope", "uksouth", "ukwest", "francecentral", "germanywestcentral", "norwayeast", "switzerlandnorth", "swedencentral", "eastasia", "southeastasia", "australiaeast", "australiasoutheast", "centralindia", "southindia", "japaneast", "japanwest", "koreacentral", "koreasouth")
if ($Region -notin $validRegions) {
    Write-Host "ERROR: Unsupported region '$Region'" -ForegroundColor Red
    Write-Host "`nSupported regions:" -ForegroundColor Yellow
    Write-Host "  Americas:  eastus, eastus2, westus, westus2, westus3, centralus, canadacentral, brazilsouth" -ForegroundColor White
    Write-Host "  Europe:    northeurope, westeurope, uksouth, francecentral, germanywestcentral, norwayeast, swedencentral" -ForegroundColor White
    Write-Host "  Asia:      eastasia, southeastasia, australiaeast, centralindia, japaneast, koreacentral" -ForegroundColor White
    Write-Host "`nExample: .\script.ps1 -Region eastus" -ForegroundColor Cyan
    throw "Unsupported region: $Region"
}

$Config = @{
    SqlRetryAttempts = 12
    SqlRetryBaseDelaySec = 20
    PropagationWaitSec = 30
    LogRetentionDays = 90
    ContainerCpu = 0.5
    ContainerMemory = "1.0Gi"
}

$ErrorActionPreference = 'Stop'
$startTime = Get-Date
$runTimestamp = Get-Date -Format "yyyyMMddHHmmss"

$script:CliLog = Join-Path $PSScriptRoot "$runTimestamp.log"

"[$(Get-Date -Format o)] CLI command log - version $Version" | Out-File $script:CliLog

Write-Host "dab-deploy-demo version $Version" -ForegroundColor Cyan
Write-Host ""

Write-Host "Checking prerequisites..." -ForegroundColor Cyan

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "  Azure CLI: " -NoNewline -ForegroundColor Yellow
    Write-Host "Not installed" -ForegroundColor Red
    Write-Host ""
    Write-Host "Azure CLI is required but not installed." -ForegroundColor Yellow
    Write-Host "Please install from: https://aka.ms/installazurecliwindows" -ForegroundColor White
    Write-Host "After installation, restart your terminal and run this script again." -ForegroundColor White
    throw "Azure CLI is not installed"
} else {
    try {
        $azVersionInfo = az version --output json 2>$null | ConvertFrom-Json
        $azVersion = $azVersionInfo.'azure-cli'
        Write-Host "  Azure CLI: " -NoNewline -ForegroundColor Yellow
        Write-Host "Installed ($azVersion)" -ForegroundColor Green
    } catch {
        Write-Host "  Azure CLI: " -NoNewline -ForegroundColor Yellow
        Write-Host "Installed (version unknown)" -ForegroundColor Green
    }
}

if (-not (Get-Command dab -ErrorAction SilentlyContinue)) {
    Write-Host "  DAB CLI: " -NoNewline -ForegroundColor Yellow
    Write-Host "Not installed" -ForegroundColor Red
    Write-Host ""
    Write-Host "Data API Builder CLI is required but not installed." -ForegroundColor Yellow
    Write-Host "Please install using: dotnet tool install -g Microsoft.DataApiBuilder" -ForegroundColor White
    Write-Host "After installation, restart your terminal and run this script again." -ForegroundColor White
    throw "DAB CLI is not installed"
} else {
    try {
        $dabVersionOutput = & dab --version 2>&1 | Out-String
        if ($dabVersionOutput -match '(\d+\.\d+\.\d+)') {
            $dabVersion = $Matches[1]
            Write-Host "  DAB CLI: " -NoNewline -ForegroundColor Yellow
            Write-Host "Installed ($dabVersion)" -ForegroundColor Green
        } else {
            Write-Host "  DAB CLI: " -NoNewline -ForegroundColor Yellow
            Write-Host "Installed (version unknown)" -ForegroundColor Green
        }
    } catch {
        Write-Host "  DAB CLI: " -NoNewline -ForegroundColor Yellow
        Write-Host "Installed (version unknown)" -ForegroundColor Green
    }
}

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Host "  sqlcmd: " -NoNewline -ForegroundColor Yellow
    Write-Host "Not installed" -ForegroundColor Red
    Write-Host ""
    Write-Host "Attempting to install SQL Server command-line tools via winget..." -ForegroundColor Cyan
    
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            winget install Microsoft.SqlServer.2022.CU --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            
            if (Get-Command sqlcmd -ErrorAction SilentlyContinue) {
                Write-Host "  sqlcmd: " -NoNewline -ForegroundColor Yellow
                Write-Host "Installed successfully" -ForegroundColor Green
            } else {
                throw "sqlcmd not found in PATH after installation"
            }
        } catch {
            Write-Host "  Automatic installation failed" -ForegroundColor Red
            Write-Host ""
            Write-Host "Please install SQL Server command-line tools manually:" -ForegroundColor Yellow
            Write-Host "  Download from: https://aka.ms/ssmsfullsetup" -ForegroundColor White
            Write-Host "  Or use: winget install Microsoft.SqlServer.2022.CU" -ForegroundColor White
            Write-Host ""
            Write-Host "After installation, restart your terminal and run this script again." -ForegroundColor White
            throw "sqlcmd installation failed: $($_.Exception.Message)"
        }
    } else {
        Write-Host "  winget not available for automatic installation" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Please install SQL Server command-line tools manually:" -ForegroundColor Yellow
        Write-Host "  Download from: https://aka.ms/ssmsfullsetup" -ForegroundColor White
        Write-Host "  Or install winget, then use: winget install Microsoft.SqlServer.2022.CU" -ForegroundColor White
        Write-Host ""
        Write-Host "After installation, restart your terminal and run this script again." -ForegroundColor White
        throw "sqlcmd is not installed and winget is not available for automatic installation"
    }
} else {
    Write-Host "  sqlcmd: " -NoNewline -ForegroundColor Yellow
    try {
        $sqlcmdVersionOutput = & sqlcmd -? 2>&1 | Out-String
        if ($sqlcmdVersionOutput -match 'Version\s+(\d+\.\d+\.\d+\.\d+)') {
            $sqlcmdVersion = $Matches[1]
            Write-Host "Installed ($sqlcmdVersion)" -ForegroundColor Green
        } else {
            Write-Host "Installed (version unknown)" -ForegroundColor Green
        }
    } catch {
        Write-Host "Installed (version unknown)" -ForegroundColor Green
    }
}

# Database validation (Deploy mode only)
if ($PSCmdlet.ParameterSetName -eq 'Deploy') {
    if (-not (Test-Path $DatabasePath)) {
        Write-Host "  database.sql: " -NoNewline -ForegroundColor Yellow
        Write-Host "Not found" -ForegroundColor Red
        Write-Host ""
        Write-Host "ERROR: database.sql not found at: $DatabasePath" -ForegroundColor Red
        Write-Host "Please create a database.sql file with your database schema and try again." -ForegroundColor Yellow
        Write-Host "Or specify a custom path: -DatabasePath <path>" -ForegroundColor Cyan
        throw "database.sql not found at: $DatabasePath"
    }

    $databaseContent = Get-Content $DatabasePath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($databaseContent)) {
        Write-Host "  database.sql: " -NoNewline -ForegroundColor Yellow
        Write-Host "Empty file" -ForegroundColor Red
        Write-Host ""
        Write-Host "ERROR: database.sql is empty at: $DatabasePath" -ForegroundColor Red
        Write-Host "The database script file is empty. Please add SQL commands to create your database." -ForegroundColor Yellow
        throw "database.sql is empty"
    }
    Write-Host "  database.sql: " -NoNewline -ForegroundColor Yellow
    Write-Host "Found" -ForegroundColor Green
}

# DAB config validation (both modes)
if (-not (Test-Path $ConfigPath)) {
    Write-Host "  dab-config.json: " -NoNewline -ForegroundColor Yellow
    Write-Host "Not found" -ForegroundColor Red
    Write-Host ""
    Write-Host "ERROR: dab-config.json not found at: $ConfigPath" -ForegroundColor Red
    Write-Host "Please create a dab-config.json file with your DAB configuration." -ForegroundColor Yellow
    Write-Host "Or specify a custom path: -ConfigPath <path>" -ForegroundColor Cyan
    throw "dab-config.json not found at: $ConfigPath"
}

try {
    $dabConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    
    $expectedEnvVar = "MSSQL_CONNECTION_STRING"
    $expectedRef = "@env('$expectedEnvVar')"
    $connectionStringRef = $dabConfig.'data-source'.'connection-string'
    
    if ($connectionStringRef -ne $expectedRef) {
        Write-Host "  dab-config.json: " -NoNewline -ForegroundColor Yellow
        Write-Host "Invalid connection string" -ForegroundColor Red
        Write-Host ""
        Write-Host "ERROR: dab-config.json has incorrect connection string reference." -ForegroundColor Red
        Write-Host "  Expected: `"connection-string`": `"$expectedRef`"" -ForegroundColor Yellow
        Write-Host "  Found:    `"connection-string`": `"$connectionStringRef`"" -ForegroundColor Red
        Write-Host ""
        Write-Host "The script sets the environment variable '$expectedEnvVar' in the container." -ForegroundColor White
        Write-Host "Please update your dab-config.json to reference this variable:" -ForegroundColor White
        Write-Host ""
        Write-Host '  "data-source": {' -ForegroundColor Cyan
        Write-Host '    "database-type": "mssql",' -ForegroundColor Cyan
        Write-Host "    `"connection-string`": `"$expectedRef`"" -ForegroundColor Green
        Write-Host '  }' -ForegroundColor Cyan
        throw "dab-config.json has incorrect connection string reference. Expected: $expectedRef, Found: $connectionStringRef"
    }
    Write-Host "  dab-config.json: " -NoNewline -ForegroundColor Yellow
    Write-Host "Found" -ForegroundColor Green
} catch {
    Write-Host "  dab-config.json: " -NoNewline -ForegroundColor Yellow
    Write-Host "Parse error" -ForegroundColor Red
    Write-Host ""
    Write-Host "ERROR: Failed to parse dab-config.json at: $ConfigPath" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Please ensure the file contains valid JSON syntax." -ForegroundColor White
    throw "Failed to parse or validate dab-config.json: $($_.Exception.Message)"
}

$dockerfilePath = "./Dockerfile"
if (-not (Test-Path $dockerfilePath)) {
    Write-Host "  Dockerfile: " -NoNewline -ForegroundColor Yellow
    Write-Host "Not found" -ForegroundColor Red
    Write-Host ""
    Write-Host "ERROR: Dockerfile not found at: $dockerfilePath" -ForegroundColor Red
    Write-Host "The script builds a custom image with dab-config.json baked in." -ForegroundColor Yellow
    Write-Host "Please ensure Dockerfile exists in the current directory." -ForegroundColor White
    throw "Dockerfile not found at: $dockerfilePath"
}
Write-Host "  Dockerfile: " -NoNewline -ForegroundColor Yellow
Write-Host "Found" -ForegroundColor Green

$configHash = (Get-FileHash $ConfigPath -Algorithm SHA256).Hash.Substring(0,8).ToLower()
Write-Host "  Config hash: " -NoNewline -ForegroundColor Yellow
Write-Host $configHash -ForegroundColor Green

Write-Host ""

Write-Host "Authenticating to Azure..." -ForegroundColor Cyan
Write-Host "This ensures you're using the correct Azure account and tenant." -ForegroundColor Gray
Write-Host ""

try {
    az login --output none 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Azure login failed"
    }
    Write-Host "Azure authentication completed successfully" -ForegroundColor Green
} catch {
    Write-Host "Azure authentication failed" -ForegroundColor Red
    Write-Host "Please ensure you have access to an Azure subscription and try again." -ForegroundColor Yellow
    throw "Azure authentication failed: $($_.Exception.Message)"
}

$tenantId = az account show --query tenantId -o tsv
$subscriptionId = az account show --query id -o tsv

function Wait-Seconds {
    param([int]$Seconds, [string]$Reason = "Waiting")
    # Silent wait - just sleep without extra output
    Start-Sleep -Seconds $Seconds
}

function Write-StepStatus {
    param(
        [string]$Step,
        
        [Parameter(Mandatory)]
        [ValidateSet('Started','Retrying','Success','Error','Info')]
        [string]$Status,
        
        [string]$Detail = ''
    )

    $timestamp = (Get-Date).ToString('HH:mm:ss')

    switch ($Status) {
        'Started' {
            if ($Step) {
                Write-Host ""
                Write-Host $Step -ForegroundColor Cyan
            }
            Write-Host "[Started] (est $Detail at $timestamp)" -ForegroundColor Yellow
        }
        'Retrying' {
            Write-Host "[Retrying] ($Detail)" -ForegroundColor DarkYellow
        }
        'Success' {
            Write-Host "[Success] ($Detail)" -ForegroundColor Green
        }
        'Error' {
            Write-Host "[Error] $Detail" -ForegroundColor Red
        }
        'Info' {
            Write-Host "[Info] $Detail" -ForegroundColor Gray
        }
    }
}

function OK { param($r, $msg) if($r.ExitCode -ne 0) { throw "$msg`n$($r.Text)" } }

function Test-AzureTokenExpiry {
    param(
        [int]$ExpiryBufferMinutes = 5
    )
    
    try {
        $tokenInfoResult = Invoke-AzCli -Arguments @('account', 'get-access-token', '--query', 'expiresOn', '--output', 'tsv')
        
        if ($tokenInfoResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($tokenInfoResult.TrimmedText)) {
            $expiresOn = [datetime]::Parse($tokenInfoResult.TrimmedText)
            $bufferTime = (Get-Date).AddMinutes($ExpiryBufferMinutes)
            
            if ($expiresOn -lt $bufferTime) {
                Write-Host "`nAccess token expired or expiring soon (expires: $expiresOn)" -ForegroundColor Yellow
                Write-Host "Refreshing Azure authentication..." -ForegroundColor Cyan
                
                az login --output none 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Token refresh failed"
                }
                
                Write-Host "Token refreshed successfully" -ForegroundColor Green
                return $true
            }
        }
    } catch {
        Write-Host "Warning: Unable to check token expiry, continuing..." -ForegroundColor Yellow
    }
    
    return $false
}

function Get-MI-DisplayName {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PrincipalId,
        
        [int]$MaxRetries = 20,
        [int]$BaseDelaySeconds = 6
    )
    
    $lastErr = $null
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            $dn = az ad sp show --id $PrincipalId --query displayName -o tsv 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($dn)) {
                return $dn.Trim()
            }

            $lastErr = "displayName not found yet"
        } catch {
            $lastErr = $_.Exception.Message
        }

        $wait = [Math]::Min(120, $BaseDelaySeconds * [Math]::Pow(1.8, ($i - 1))) + (Get-Random -Minimum 0 -Maximum 4)
        Write-Host "[Retrying] (service principal propagation; attempt $i/$MaxRetries, wait ${wait}s)" -ForegroundColor DarkYellow
        Start-Sleep -Seconds ([int][Math]::Round($wait))
    }
    
    throw "Unable to resolve managed identity display name for SP '$PrincipalId' after $MaxRetries attempts. Last error: $lastErr"
}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $cmd = "az " + ($Arguments -join ' ')

    $output = & az @Arguments 2>&1
    $exitCode = $global:LASTEXITCODE
    $text = $output | Out-String

    $timestamp = Get-Date -Format o
    $tag = if ($exitCode -eq 0) { "[OK]" } else { "[ERR]" }
    Add-Content -Path $script:CliLog -Value "$timestamp $tag $cmd"
    Add-Content -Path $script:CliLog -Value $text

    [pscustomobject]@{
        ExitCode    = $exitCode
        Output      = $output
        Text        = $text
        TrimmedText = $text.Trim()
    }
}

function Write-DeploymentSummary {
    param(
        $ResourceGroup, $Region, $SqlServer, $SqlDatabase, $Container, $ContainerUrl,
        $LogAnalytics, $Environment, $CurrentUser, $DatabaseType, $TotalTime, $ClientIp, $SqlServerFqdn, $FirewallRuleName
    )
    
    $subscriptionIdResult = Invoke-AzCli -Arguments @('account', 'show', '--query', 'id', '--output', 'tsv')
    OK $subscriptionIdResult "Failed to retrieve subscription id for summary"
    $subscriptionId = $subscriptionIdResult.TrimmedText
    
    Write-Host "`n" -NoNewline
    Write-Host "================================================================================"
    Write-Host "  DAB DEMO DEPLOYMENT SUMMARY" -ForegroundColor Green
    Write-Host "================================================================================"
    
    Write-Host "`nRESOURCES CREATED" -ForegroundColor Cyan
    Write-Host "  Resource Group:    $ResourceGroup"
    Write-Host "  Region:            $Region"
    Write-Host ""
    Write-Host "  SQL Server:        $SqlServer"
    Write-Host "    Database:        $SqlDatabase ($DatabaseType)"
    Write-Host "    Auth Method:     Azure AD Only"
    Write-Host "    Admin:           $CurrentUser"
    Write-Host "    Purpose:         Hosts demo database with managed identity access"
    Write-Host ""
    Write-Host "  Container App:     $Container"
    Write-Host "    Environment:     $Environment"
    Write-Host "    Identity:        System-assigned managed identity"
    Write-Host "    Purpose:         Runs Data API Builder with SQL connectivity"
    Write-Host "    Config:          Baked into container image at /App/dab-config.json"
    Write-Host ""
    Write-Host "  Log Analytics:     $LogAnalytics"
    Write-Host "    Purpose:         Container Apps environment logging"
    
    Write-Host "`nENDPOINTS" -ForegroundColor Cyan
    Write-Host "  DAB API:          $ContainerUrl"
    Write-Host "  SQL Server:       $SqlServerFqdn"
    Write-Host "  Logs (CLI):       az containerapp logs show -n $Container -g $ResourceGroup --follow"
    Write-Host "  Portal RG:        https://portal.azure.com/#view/HubsExtension/BrowseResourceGroups/resourceGroup/$ResourceGroup"
    Write-Host "  Portal SQL:       https://portal.azure.com/#@/resource/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Sql/servers/$SqlServer"
    Write-Host "  Portal Container: https://portal.azure.com/#@/resource/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/containerApps/$Container"
    Write-Host "  Portal Logs:      https://portal.azure.com/#@/resource/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$LogAnalytics"
    
    Write-Host "`nNEXT STEPS" -ForegroundColor Yellow
    $configStatus = if (Test-Path "./dab-config.json") { "auto-configured" } else { "requires manual dab-config.json" }
    $configColor = if (Test-Path "./dab-config.json") { "Green" } else { "Yellow" }
    Write-Host "  DAB Config:       $configStatus" -ForegroundColor $configColor
    Write-Host "  1. Test API: curl $ContainerUrl/api/[entity]"
    Write-Host "  2. View logs: az containerapp logs show -n $Container -g $ResourceGroup --follow"
    Write-Host "  3. Cleanup:  az group delete -n $ResourceGroup -y"
    
    Write-Host "`nSECURITY NOTE" -ForegroundColor DarkYellow
    Write-Host "  Your local IP ($ClientIp) has been allowed in the SQL Server firewall."
    Write-Host "  Remove when no longer needed: az sql server firewall-rule delete -g $ResourceGroup -s $SqlServer -n $FirewallRuleName"
    
    Write-Host "`nDEPLOYMENT INFO" -ForegroundColor Magenta
    Write-Host "  Total time: $TotalTime"
    Write-Host "  Version: $Version"
    Write-Host "  PowerShell: $($PSVersionTable.PSVersion)"
    Write-Host "  Timestamp: $runTimestamp"
    
    Write-Host "================================================================================"
}

function Assert-ResourceNameLength {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        
        [Parameter(Mandatory)]
        [ValidateSet(
            'ResourceGroup',
            'SqlServer',
            'Database',
            'ContainerApp',
            'ContainerEnvironment',
            'LogAnalytics'
        )]
        [string]$ResourceType,
        
        [int]$MaxLength = 0
    )
    
    $limits = @{
        'ResourceGroup'        = 90
        'SqlServer'            = 63
        'Database'             = 128
        'ContainerApp'         = 32
        'ContainerEnvironment' = 60
        'LogAnalytics'         = 63
    }
    
    $maxLen = if ($MaxLength -gt 0) { $MaxLength } else { $limits[$ResourceType] }
    
    if ($Name.Length -gt $maxLen) {
        $trimmedName = $Name.Substring(0, $maxLen)
        return $trimmedName
    }
    
    return $Name
}

$accountInfoResult = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json')
OK $accountInfoResult "Failed to retrieve account information after login"

$accountInfo = $accountInfoResult.TrimmedText | ConvertFrom-Json
$currentSub = $accountInfo.name
$currentSubId = $accountInfo.id
$currentAccountUser = $accountInfo.user?.name
if (-not $currentAccountUser) { $currentAccountUser = $accountInfo.user?.userName }
if (-not $currentAccountUser) { $currentAccountUser = $accountInfo.user?.userPrincipalName }
if (-not $currentAccountUser) { $currentAccountUser = "unknown-principal" }

$ownerTagValue = "unknown-owner"
if ($currentAccountUser -and $currentAccountUser -match '^([^@]+)@') {
    $ownerLocalPart = $Matches[1]
    if ($ownerLocalPart) {
        $ownerTagValue = ($ownerLocalPart -replace '[^a-z0-9._-]', '-').ToLowerInvariant()
    }
}
$commonTagValues = @('author=dab-deploy-demo-script', "version=$Version", "owner=$ownerTagValue")

Write-Host "`nCurrent subscription:" -ForegroundColor Cyan
Write-Host "  Name: $currentSub" -ForegroundColor White
Write-Host "  ID:   $currentSubId" -ForegroundColor DarkGray

if (-not $Force) {
    $confirm = Read-Host "`nDeploy to this subscription? (y/n/list) [y]"
    if ($confirm) { $confirm = $confirm.Trim().ToLowerInvariant() }

    if ($confirm -eq 'list' -or $confirm -eq 'l') {
        Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
        $subscriptionListResult = Invoke-AzCli -Arguments @('account', 'list', '--query', '[].{name:name, id:id, isDefault:isDefault}', '--output', 'json')
        OK $subscriptionListResult "Failed to list subscriptions"
        $subscriptions = $subscriptionListResult.TrimmedText | ConvertFrom-Json
        
        for ($i = 0; $i -lt $subscriptions.Count; $i++) {
            $sub = $subscriptions[$i]
            $marker = if ($sub.isDefault) { " (current)" } else { "" }
            $color = if ($sub.isDefault) { "Green" } else { "White" }
            Write-Host "$($i + 1). $($sub.name)$marker" -ForegroundColor $color
            Write-Host "   ID: $($sub.id)" -ForegroundColor DarkGray
        }
        
        do {
            $choice = Read-Host "`nSelect subscription (1-$($subscriptions.Count)) or press Enter to keep current"
            if ([string]::IsNullOrWhiteSpace($choice)) { 
                break 
            }
        } while ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $subscriptions.Count)
        
        if (-not [string]::IsNullOrWhiteSpace($choice)) {
            $selectedSub = $subscriptions[[int]$choice - 1]
            Write-Host "Switching to subscription: $($selectedSub.name)" -ForegroundColor Yellow
            $setSubscriptionResult = Invoke-AzCli -Arguments @('account', 'set', '--subscription', $selectedSub.id)
            OK $setSubscriptionResult "Failed to switch subscription"
            $accountInfoResult = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json')
            OK $accountInfoResult "Failed to refresh subscription context"
            $accountInfo = $accountInfoResult.TrimmedText | ConvertFrom-Json
            $currentSub = $accountInfo.name
            $currentSubId = $accountInfo.id
            Write-Host "Now using: $currentSub" -ForegroundColor Green
        }
    } elseif ($confirm -and $confirm -ne 'y') {
        Write-Host "Deployment cancelled by user" -ForegroundColor Yellow
        exit 0
    }
    
    $estimatedFinishTime = (Get-Date).AddMinutes(8).ToString("HH:mm:ss")
    Write-Host "`nStarting deployment. Estimated time to complete: 8m (finish ~$estimatedFinishTime)" -ForegroundColor Cyan
} else {
    Write-Host "  -Force specified: skipping confirmation" -ForegroundColor Yellow
    $estimatedFinishTime = (Get-Date).AddMinutes(8).ToString("HH:mm:ss")
    Write-Host "`nStarting deployment. Estimated time to complete: 8m (finish ~$estimatedFinishTime)" -ForegroundColor Cyan
}

try {
    [void](Test-AzureTokenExpiry -ExpiryBufferMinutes 5)
    
    # Detect parameter set mode
    if ($PSCmdlet.ParameterSetName -eq 'UpdateImage') {
        # ============================================================================
        # UPDATE IMAGE MODE
        # ============================================================================
        $updateStartTime = Get-Date
        $rg = $UpdateImage
        
        Write-Host "`n================================================================================" -ForegroundColor Cyan
        Write-Host "  UPDATE IMAGE MODE" -ForegroundColor Cyan
        Write-Host "================================================================================" -ForegroundColor Cyan
        Write-Host "  Resource Group: $rg" -ForegroundColor White
        Write-Host "  Config File:    $ConfigPath" -ForegroundColor White
        Write-Host ""
        
        # Subscription confirmation (same as Deploy mode)
        if (-not $Force) {
            $confirm = Read-Host "`nUpdate resources in this subscription? (y/n/list) [y]"
            if ($confirm) { $confirm = $confirm.Trim().ToLowerInvariant() }

            if ($confirm -eq 'list' -or $confirm -eq 'l') {
                Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
                $subscriptionListResult = Invoke-AzCli -Arguments @('account', 'list', '--query', '[].{name:name, id:id, isDefault:isDefault}', '--output', 'json')
                OK $subscriptionListResult "Failed to list subscriptions"
                $subscriptions = $subscriptionListResult.TrimmedText | ConvertFrom-Json
                
                for ($i = 0; $i -lt $subscriptions.Count; $i++) {
                    $sub = $subscriptions[$i]
                    $marker = if ($sub.isDefault) { " (current)" } else { "" }
                    $color = if ($sub.isDefault) { "Green" } else { "White" }
                    Write-Host "$($i + 1). $($sub.name)$marker" -ForegroundColor $color
                    Write-Host "   ID: $($sub.id)" -ForegroundColor DarkGray
                }
                
                do {
                    $choice = Read-Host "`nSelect subscription (1-$($subscriptions.Count)) or press Enter to keep current"
                    if ([string]::IsNullOrWhiteSpace($choice)) { 
                        break 
                    }
                } while ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $subscriptions.Count)
                
                if (-not [string]::IsNullOrWhiteSpace($choice)) {
                    $selectedSub = $subscriptions[[int]$choice - 1]
                    Write-Host "Switching to subscription: $($selectedSub.name)" -ForegroundColor Yellow
                    $setSubscriptionResult = Invoke-AzCli -Arguments @('account', 'set', '--subscription', $selectedSub.id)
                    OK $setSubscriptionResult "Failed to switch subscription"
                    $accountInfoResult = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json')
                    OK $accountInfoResult "Failed to refresh subscription context"
                    $accountInfo = $accountInfoResult.TrimmedText | ConvertFrom-Json
                    $currentSub = $accountInfo.name
                    $currentSubId = $accountInfo.id
                    Write-Host "Now using: $currentSub" -ForegroundColor Green
                }
            } elseif ($confirm -and $confirm -ne 'y') {
                Write-Host "Update cancelled by user" -ForegroundColor Yellow
                exit 0
            }
            
            $estimatedFinishTime = (Get-Date).AddMinutes(3).ToString("HH:mm:ss")
            Write-Host "`nStarting image update. Estimated time to complete: 3m (finish ~$estimatedFinishTime)" -ForegroundColor Cyan
        } else {
            Write-Host "  -Force specified: skipping confirmation" -ForegroundColor Yellow
            $estimatedFinishTime = (Get-Date).AddMinutes(3).ToString("HH:mm:ss")
            Write-Host "`nStarting image update. Estimated time to complete: 3m (finish ~$estimatedFinishTime)" -ForegroundColor Cyan
        }
        
        # Verify resource group exists
        Write-StepStatus "Verifying resource group" "Started" "5s"
        $rgCheckResult = Invoke-AzCli -Arguments @('group', 'exists', '--name', $rg)
        if ($rgCheckResult.TrimmedText -ne 'true') {
            throw "Resource group '$rg' does not exist. Cannot update."
        }
        Write-StepStatus "" "Success" "Resource group exists"
        
        # Discover existing resources
        Write-StepStatus "Discovering existing resources" "Started" "5s"
        
        # Find ACR
        $acrListResult = Invoke-AzCli -Arguments @('acr', 'list', '--resource-group', $rg, '--query', "[?tags.author=='dab-deploy-demo-script'].name", '--output', 'tsv')
        if ([string]::IsNullOrWhiteSpace($acrListResult.TrimmedText)) {
            throw "No ACR found in resource group '$rg' with expected tags (author=dab-deploy-demo-script)"
        }
        $acrName = $acrListResult.TrimmedText.Trim()
        Write-Host "  Found ACR: $acrName" -ForegroundColor Gray
        
        # Get ACR login server
        $acrLoginServerResult = Invoke-AzCli -Arguments @('acr', 'show', '--name', $acrName, '--resource-group', $rg, '--query', 'loginServer', '--output', 'tsv')
        OK $acrLoginServerResult "Failed to get ACR login server"
        $acrLoginServer = $acrLoginServerResult.TrimmedText
        
        # Find Container App
        $containerListResult = Invoke-AzCli -Arguments @('containerapp', 'list', '--resource-group', $rg, '--query', "[?tags.author=='dab-deploy-demo-script'].name", '--output', 'tsv')
        if ([string]::IsNullOrWhiteSpace($containerListResult.TrimmedText)) {
            throw "No Container App found in resource group '$rg' with expected tags (author=dab-deploy-demo-script)"
        }
        $container = $containerListResult.TrimmedText.Trim()
        Write-Host "  Found Container App: $container" -ForegroundColor Gray
        
        Write-StepStatus "" "Success" "Resources discovered"
        
        # Generate config hash
        $configHash = (Get-FileHash $ConfigPath -Algorithm SHA256).Hash.Substring(0,8).ToLower()
        Write-Host "  New config hash: $configHash" -ForegroundColor Gray
        
        # Check if image with same hash already exists
        $imageTag = "$acrLoginServer/dab-baked:$configHash"
        $existingTagsResult = Invoke-AzCli -Arguments @('acr', 'repository', 'show-tags', '--name', $acrName, '--repository', 'dab-baked', '--output', 'json')
        if ($existingTagsResult.ExitCode -eq 0) {
            $existingTags = $existingTagsResult.TrimmedText | ConvertFrom-Json
            if ($existingTags -contains $configHash) {
                Write-Host "`n  Image with this config already exists in ACR" -ForegroundColor Yellow
                $response = Read-Host "  Continue with existing image? (y/n) [y]"
                if ($response -and $response -ne 'y') {
                    Write-Host "`nUpdate cancelled by user." -ForegroundColor Yellow
                    exit 0
                }
            }
        }
        
        # Build new image
        Write-StepStatus "Building updated DAB image" "Started" "40s"
        $buildStartTime = Get-Date
        
        $buildArgs = @('acr', 'build', '--resource-group', $rg, '--registry', $acrName, '--image', $imageTag, '--file', 'Dockerfile', '.')
        $buildResult = Invoke-AzCli -Arguments $buildArgs
        OK $buildResult "Failed to build updated DAB image"
        
        $buildElapsed = [math]::Round(((Get-Date) - $buildStartTime).TotalSeconds, 1)
        Write-StepStatus "" "Success" "$imageTag (${buildElapsed}s)"
        
        # Update container app
        Write-StepStatus "Updating container app with new image" "Started" "30s"
        $updateAppStartTime = Get-Date
        
        $updateArgs = @(
            'containerapp', 'update',
            '--name', $container,
            '--resource-group', $rg,
            '--image', $imageTag
        )
        
        $updateResult = Invoke-AzCli -Arguments $updateArgs
        OK $updateResult "Failed to update container app"
        
        $updateElapsed = [math]::Round(((Get-Date) - $updateAppStartTime).TotalSeconds, 1)
        Write-StepStatus "" "Success" "Container updated (${updateElapsed}s)"
        
        # Wait for new revision to become ready
        Write-StepStatus "Waiting for new revision to become ready" "Started" "2min"
        
        $maxWaitMinutes = 2
        $checkDeadline = (Get-Date).AddMinutes($maxWaitMinutes)
        $revisionReady = $false
        
        while (-not $revisionReady -and (Get-Date) -lt $checkDeadline) {
            Start-Sleep -Seconds 10
            
            $statusArgs = @('containerapp', 'show', '--name', $container, '--resource-group', $rg, '--query', '{running:properties.runningStatus,revision:properties.latestReadyRevisionName}', '--output', 'json')
            $statusResult = Invoke-AzCli -Arguments $statusArgs
            
            if ($statusResult.ExitCode -eq 0) {
                $cleanedJson = $statusResult.TrimmedText -replace '(?m)^WARNING:.*$', ''
                $status = $cleanedJson.Trim() | ConvertFrom-Json
                
                if ($status.running -eq 'Running') {
                    $revisionReady = $true
                    Write-StepStatus "" "Success" "New revision ready: $($status.revision)"
                }
            }
        }
        
        if (-not $revisionReady) {
            throw "New revision did not become ready within $maxWaitMinutes minutes"
        }
        
        # Get container URL
        $fqdnResult = Invoke-AzCli -Arguments @('containerapp', 'show', '--name', $container, '--resource-group', $rg, '--query', 'properties.configuration.ingress.fqdn', '--output', 'tsv')
        $cleanFqdn = ($fqdnResult.TrimmedText -split "`n" | Where-Object { $_ -notmatch '^WARNING:' }) -join ''
        $containerUrl = "https://$($cleanFqdn.Trim())"
        
        # Health check
        Write-StepStatus "Verifying DAB API health" "Started" "30s"
        $healthCheckStartTime = Get-Date
        $healthCheckPassed = $false
        
        for ($i = 1; $i -le 5; $i++) {
            try {
                $healthResponse = Invoke-RestMethod -Uri "$containerUrl/health" -TimeoutSec 10 -ErrorAction Stop
                if ($healthResponse.status -eq "Healthy") {
                    $healthElapsed = [math]::Round(((Get-Date) - $healthCheckStartTime).TotalSeconds, 1)
                    Write-StepStatus "" "Success" "API is healthy (${healthElapsed}s)"
                    $healthCheckPassed = $true
                    break
                }
            } catch {
                if ($i -lt 5) {
                    Start-Sleep -Seconds 10
                } else {
                    Write-Host "  Warning: Health check failed after 5 attempts" -ForegroundColor Yellow
                    Write-Host "  The container may still be starting up" -ForegroundColor Yellow
                }
            }
        }
        
        # Summary
        $totalTime = [math]::Round(((Get-Date) - $updateStartTime).TotalMinutes, 1)
        
        Write-Host "`n================================================================================" -ForegroundColor Green
        Write-Host "  ✓ IMAGE UPDATE SUCCESSFUL" -ForegroundColor Green
        Write-Host "================================================================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "UPDATED RESOURCES" -ForegroundColor Cyan
        Write-Host "  Resource Group:    $rg" -ForegroundColor White
        Write-Host "  Container App:     $container" -ForegroundColor White
        Write-Host "  New Image:         $imageTag" -ForegroundColor White
        Write-Host "  API Endpoint:      $containerUrl" -ForegroundColor White
        Write-Host ""
        Write-Host "UPDATE INFO" -ForegroundColor Magenta
        Write-Host "  Total time:        ${totalTime}m" -ForegroundColor White
        Write-Host "  Config hash:       $configHash" -ForegroundColor White
        Write-Host "  Health check:      $(if ($healthCheckPassed) { 'Passed' } else { 'Skipped' })" -ForegroundColor White
        Write-Host ""
        Write-Host "================================================================================" -ForegroundColor Green
        
        exit 0
    }
    
    # ============================================================================
    # DEPLOY MODE (original logic)
    # ============================================================================
    $rg = "dab-demo-$runTimestamp"
    $acaEnv = "aca-environment"
    $container = "data-api-container"
    $sqlServer = "sql-server-$runTimestamp"
    $sqlDb = "sql-database"
    $logAnalytics = "log-workspace"
    $acrName = "acr$runTimestamp"
    
    $rg = Assert-ResourceNameLength -Name $rg -ResourceType 'ResourceGroup'
    $acaEnv = Assert-ResourceNameLength -Name $acaEnv -ResourceType 'ContainerEnvironment'
    $container = Assert-ResourceNameLength -Name $container -ResourceType 'ContainerApp'
    $sqlServer = Assert-ResourceNameLength -Name $sqlServer -ResourceType 'SqlServer'
    $sqlDb = Assert-ResourceNameLength -Name $sqlDb -ResourceType 'Database'
    $logAnalytics = Assert-ResourceNameLength -Name $logAnalytics -ResourceType 'LogAnalytics'

    Write-StepStatus "Creating resource group" "Started" "5s"
    $rgStartTime = Get-Date
    $rgArgs = @('group', 'create', '--name', $rg, '--location', $Region, '--tags') + $commonTagValues
    $rgCreateResult = Invoke-AzCli -Arguments $rgArgs
    if ($rgCreateResult.ExitCode -ne 0) {
        $rgError = $rgCreateResult.TrimmedText
        if ($rgError -match "AuthorizationFailed") {
            $guidanceLines = @(
                "AuthorizationFailed: The signed-in account '$currentAccountUser' cannot create resource groups in subscription '$currentSub'.",
                "",
                "What to try next:",
                "  1. Confirm you targeted the right subscription: az account list --output table",
                "  2. If you recently changed tenants or accounts, refresh credentials: az login [--tenant <tenant-id>]",
                "  3. Ask a subscription Owner to grant you the Contributor role.",
                "",
                "Raw Azure CLI error:",
                "  $rgError"
            )
            throw ($guidanceLines -join "`n")
        }
        throw "Failed to create resource group. Azure CLI returned: $rgError"
    }
    $rgElapsed = [math]::Round(((Get-Date) - $rgStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$rg (${rgElapsed}s)"

    Write-StepStatus "Getting current Azure AD user" "Started" "5s"
    $userInfoResult = Invoke-AzCli -Arguments @('ad', 'signed-in-user', 'show', '--query', '{id:id,upn:userPrincipalName}', '--output', 'json')
    OK $userInfoResult "Failed to identify Azure AD user"
    $userInfo = $userInfoResult.TrimmedText | ConvertFrom-Json
    $currentUser = $userInfo.id
    $currentUserName = $userInfo.upn
    Write-StepStatus "" "Success" "retrieved $currentUserName"

    Write-StepStatus "Creating SQL Server" "Started" "1min 20s"
    
    $sqlStartTime = Get-Date
    $sqlServerArgs = @(
        'sql', 'server', 'create',
        '--name', $sqlServer,
        '--resource-group', $rg,
        '--location', $Region,
        '--enable-ad-only-auth',
        '--external-admin-principal-type', 'User',
        '--external-admin-name', $currentUserName,
        '--external-admin-sid', $currentUser
    )
    $sqlServerResult = Invoke-AzCli -Arguments $sqlServerArgs
    OK $sqlServerResult "Failed to create SQL server"
    
    $sqlTagArgs = @('sql', 'server', 'update', '--name', $sqlServer, '--resource-group', $rg, '--set')
    foreach ($tag in $commonTagValues) {
        if ($tag -match '^([^=]+)=(.+)$') {
            $sqlTagArgs += "tags.$($Matches[1])=$($Matches[2])"
        }
    }
    $sqlTagResult = Invoke-AzCli -Arguments $sqlTagArgs
    OK $sqlTagResult "Failed to apply tags to SQL server"
    
    $sqlElapsed = [math]::Round(((Get-Date) - $sqlStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$sqlServer (${sqlElapsed}s)"
    
    $sqlFqdnArgs = @('sql', 'server', 'show', '--name', $sqlServer, '--resource-group', $rg, '--query', 'fullyQualifiedDomainName', '--output', 'tsv')
    $sqlFqdnResult = Invoke-AzCli -Arguments $sqlFqdnArgs
    OK $sqlFqdnResult "Failed to retrieve SQL Server FQDN"
    $sqlServerFqdn = $sqlFqdnResult.TrimmedText

    $startIp = "0.0.0.0"
    $endIp = "255.255.255.255"
    $clientIp = "$startIp-$endIp"
    
    $firewallRuleName = "AllowAll"
    $firewallArgs = @(
        'sql', 'server', 'firewall-rule', 'create',
        '--resource-group', $rg,
        '--server', $sqlServer,
        '--name', $firewallRuleName,
        '--start-ip-address', $startIp,
        '--end-ip-address', $endIp
    )
    
    $firewallResult = Invoke-AzCli -Arguments $firewallArgs
    OK $firewallResult "Failed to create firewall rule"

    if ($VerifyAdOnlyAuth) {
        Write-StepStatus "Verifying Entra ID-only authentication (optional check)" "Started" "3min"
        $adOnlyReady = $false
        
        for ($i = 1; $i -le 10; $i++) {
            $adOnlyStateArgs = @('sql', 'server', 'ad-only-auth', 'get', '--resource-group', $rg, '--server-name', $sqlServer, '--query', 'azureAdOnlyAuthentication', '--output', 'tsv')
            $adOnlyStateResult = Invoke-AzCli -Arguments $adOnlyStateArgs
            
            if ($adOnlyStateResult.ExitCode -eq 0 -and $adOnlyStateResult.TrimmedText -eq 'true') {
                $adOnlyReady = $true
                Write-StepStatus "" "Success" "active"
                break
            }
            
            $delay = [Math]::Min(120, 5 * [Math]::Pow(1.7, $i))
            Write-StepStatus "" "Retrying" "attempt $i/10, waiting ${delay}s"
            Start-Sleep -Seconds ([int]$delay)
        }
        
        if (-not $adOnlyReady) {
            Write-StepStatus "" "Info" "not confirmed after 10 attempts, proceeding anyway"
        }
    }

    Write-StepStatus "Checking free database capacity" "Started" "5s"
    $freeCheckStartTime = Get-Date
    $canUseFree = $false
    
    try {
        $freeCapArgs = @('sql', 'server', 'list-usages', '--resource-group', $rg, '--name', $sqlServer, '--query', "[?name.value=='FreeDatabaseCount']", '--output', 'json')
        $freeCapResult = Invoke-AzCli -Arguments $freeCapArgs
        
        if ($freeCapResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($freeCapResult.TrimmedText)) {
            $freeCapJson = $freeCapResult.TrimmedText | ConvertFrom-Json
            if ($freeCapJson -and $freeCapJson.Count -gt 0) {
                $currentVal = [int]$freeCapJson[0].currentValue
                $limitVal = [int]$freeCapJson[0].limit
                if ($currentVal -lt $limitVal) {
                    $canUseFree = $true
                }
            }
        }
    } catch {
        $canUseFree = $false
    }
    
    $freeCheckElapsed = [math]::Round(((Get-Date) - $freeCheckStartTime).TotalSeconds, 1)
    
    if ($canUseFree) {
        Write-StepStatus "" "Success" "Free tier available (${freeCheckElapsed}s)"
    } else {
        Write-StepStatus "" "Success" "Free tier unavailable, using DTU (${freeCheckElapsed}s)"
    }

    if ($canUseFree) {
        Write-StepStatus "Creating SQL database" "Started" "20s"
    } else {
        Write-StepStatus "Creating SQL database" "Started" "1min"
    }
    
    $dbStartTime = Get-Date
    $dbCreated = $false
    
    if ($canUseFree) {
        $freeDbArgs = @('sql', 'db', 'create', '--name', $sqlDb, '--server', $sqlServer, '--resource-group', $rg, '--tags') + $commonTagValues + @('--use-free-limit', 'true', '--edition', 'Free', '--max-size', '1GB', '--query', 'name', '--output', 'tsv')
        $freeDbAttempt = Invoke-AzCli -Arguments $freeDbArgs
        $freeDbOutput = $freeDbAttempt.TrimmedText
        
        if ($freeDbAttempt.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($freeDbOutput)) {
            $dbType = "Free-tier"
            $dbCreated = $true
        } else {
            Write-StepStatus "" "Info" "Free-tier failed, trying Basic DTU"
        }
    }
    
    if (-not $dbCreated) {
        $fallbackDbArgs = @(
            'sql', 'db', 'create',
            '--name', $sqlDb,
            '--server', $sqlServer,
            '--resource-group', $rg,
            '--edition', 'Basic',
            '--service-objective', 'Basic',
            '--tags') + $commonTagValues
        $fallbackDbResult = Invoke-AzCli -Arguments $fallbackDbArgs
        OK $fallbackDbResult "Failed to create fallback SQL database"
        $dbType = "Basic DTU (paid)"
    }
    
    $dbElapsed = [math]::Round(((Get-Date) - $dbStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$sqlDb ($dbType, ${dbElapsed}s)"

    if (Test-Path $DatabasePath) {
        Write-StepStatus "Deploying database schema" "Started" "30s"
        $schemaStartTime = Get-Date
        $schemaRetries = 0
        $maxSchemaRetries = 3
        $schemaSuccess = $false
        
        while (-not $schemaSuccess -and $schemaRetries -lt $maxSchemaRetries) {
            $schemaRetries++
            
            $sqlcmdOutput = sqlcmd -S $sqlServerFqdn -d $sqlDb -G -i $DatabasePath 2>&1 | Out-String
            $sqlExit = $LASTEXITCODE
            
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            
            if ($sqlExit -eq 0) {
                Add-Content -Path $script:CliLog -Value "[$timestamp] [OK] sqlcmd -S $sqlServerFqdn -d $sqlDb -G -i $DatabasePath`n$sqlcmdOutput`n"
                $schemaElapsed = [math]::Round(((Get-Date) - $schemaStartTime).TotalSeconds, 1)
                Write-StepStatus "" "Success" "schema deployed to $sqlDb (${schemaElapsed}s)"
                $schemaSuccess = $true
            } else {
                Add-Content -Path $script:CliLog -Value "[$timestamp] [ERR] sqlcmd -S $sqlServerFqdn -d $sqlDb -G -i $DatabasePath (attempt $schemaRetries/$maxSchemaRetries)`n$sqlcmdOutput`n"
                
                $isAdAuthError = $sqlcmdOutput -match "Login failed.*AzureAD" -or 
                                 $sqlcmdOutput -match "Azure.*authentication.*not.*ready" -or
                                 $sqlcmdOutput -match "configured for Azure AD only authentication"
                
                $isPermissionError = $sqlcmdOutput -match "permission.*denied" -or
                                    $sqlcmdOutput -match "The user does not have permission"
                
                if ($schemaRetries -lt $maxSchemaRetries -and $isAdAuthError) {
                    $waitSeconds = 15
                    Write-StepStatus "" "Retrying" "Azure AD auth not ready, attempt $schemaRetries/$maxSchemaRetries, waiting ${waitSeconds}s"
                    Start-Sleep -Seconds $waitSeconds
                } elseif ($isPermissionError) {
                    Write-StepStatus "" "Error" "Permission denied. User $currentUserName may lack CREATE TABLE or ALTER permissions"
                    Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
                    Write-Host "  - Verify $currentUserName is set as SQL Server admin" -ForegroundColor White
                    Write-Host "  - Check firewall allows your IP" -ForegroundColor White
                    Write-Host "  - Ensure database.sql has valid permissions" -ForegroundColor White
                    throw "Database schema deployment failed: Permission denied (exit code $sqlExit)"
                } elseif ($schemaRetries -ge $maxSchemaRetries) {
                    Write-StepStatus "" "Error" "Failed after $maxSchemaRetries attempts (exit code $sqlExit)"
                    Write-Host "`nError details from sqlcmd:" -ForegroundColor Yellow
                    Write-Host $sqlcmdOutput -ForegroundColor DarkYellow
                    Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
                    Write-Host "  - Check logs: $script:CliLog" -ForegroundColor White
                    Write-Host "  - Verify Azure AD authentication: az sql server ad-only-auth get -g $rg -n $sqlServer" -ForegroundColor White
                    Write-Host "  - Test connectivity: sqlcmd -S $sqlServerFqdn -d $sqlDb -G -Q 'SELECT @@VERSION'" -ForegroundColor White
                    if ($isAdAuthError) {
                        Write-Host "  - Azure AD auth error detected. Try running with -VerifyAdOnlyAuth flag" -ForegroundColor Cyan
                    }
                    throw "Database schema deployment failed after $maxSchemaRetries attempts (exit code $sqlExit)"
                } else {
                    Write-StepStatus "" "Error" "sqlcmd exit code $sqlExit. See $script:CliLog"
                    throw "Database schema deployment failed with exit code $sqlExit"
                }
            }
        }
    } else {
        throw "database.sql file validation failed at path: $DatabasePath"
    }

    Write-StepStatus "Validating DAB configuration" "Started" "5s"
    $validationStartTime = Get-Date
    
    $validationConnectionString = "Server=tcp:${sqlServerFqdn},1433;Database=${sqlDb};Authentication=Active Directory Default;"
    
    $env:MSSQL_CONNECTION_STRING = $validationConnectionString
    
    $dabInstalled = Get-Command dab -ErrorAction SilentlyContinue
    if (-not $dabInstalled) {
        if ($Force) {
            Write-StepStatus "" "Error" "DAB CLI not found in CI/automation mode"
            throw "DAB CLI is required for validation in CI/automation mode. Install it before running this script."
        }
        
        Write-StepStatus "" "Info" "DAB CLI not installed, skipping validation"
    } else {
        try {
            $dabOutput = & dab validate --config $ConfigPath 2>&1
            $dabExit = $LASTEXITCODE
            
            if ($dabExit -ne 0) {
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Add-Content -Path $script:CliLog -Value "[$timestamp] [ERR] dab validate --config $ConfigPath`n$dabOutput`n"
                
                Write-StepStatus "" "Error" "Configuration validation failed. See $script:CliLog"
                throw "DAB configuration validation failed. Fix errors in $ConfigPath and database schema before deploying."
            } else {
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Add-Content -Path $script:CliLog -Value "[$timestamp] [OK] dab validate --config $ConfigPath`nConfiguration valid`n"
                
                $validationElapsed = [math]::Round(((Get-Date) - $validationStartTime).TotalSeconds, 1)
                Write-StepStatus "" "Success" "$ConfigPath validated (${validationElapsed}s)"
            }
        } finally {
            Remove-Item Env:MSSQL_CONNECTION_STRING -ErrorAction SilentlyContinue
        }
    }

    Write-StepStatus "Creating Log Analytics workspace" "Started" "40s"
    $lawStartTime = Get-Date
    $lawCreateArgs = @('monitor', 'log-analytics', 'workspace', 'create', '--resource-group', $rg, '--workspace-name', $logAnalytics, '--location', $Region, '--tags') + $commonTagValues
    $lawCreateResult = Invoke-AzCli -Arguments $lawCreateArgs
    OK $lawCreateResult "Failed to create Log Analytics workspace"
    
    $lawCustomerIdArgs = @('monitor', 'log-analytics', 'workspace', 'show', '--resource-group', $rg, '--workspace-name', $logAnalytics, '--query', 'customerId', '--output', 'tsv')
    $lawCustomerIdResult = Invoke-AzCli -Arguments $lawCustomerIdArgs
    OK $lawCustomerIdResult "Failed to get Log Analytics customerId"
    $lawCustomerId = $lawCustomerIdResult.TrimmedText.Trim()
    
    if ($lawCustomerId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw "Log Analytics customerId is not a valid 36-character GUID. Got: '$lawCustomerId'"
    }
    
    $lawKeyArgs = @('monitor', 'log-analytics', 'workspace', 'get-shared-keys', '--resource-group', $rg, '--workspace-name', $logAnalytics, '--query', 'primarySharedKey', '--output', 'tsv')
    $lawKeyResult = Invoke-AzCli -Arguments $lawKeyArgs
    OK $lawKeyResult "Failed to get Log Analytics workspace key"
    $lawPrimaryKey = $lawKeyResult.TrimmedText.Trim()
    
    if ([string]::IsNullOrWhiteSpace($lawPrimaryKey)) {
        throw "Log Analytics primarySharedKey came back empty"
    }
    
    $lawElapsed = [math]::Round(((Get-Date) - $lawStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$logAnalytics (${lawElapsed}s)"

    Write-StepStatus "Updating Log Analytics retention" "Started" "35s"
    $lawUpdateArgs = @('monitor', 'log-analytics', 'workspace', 'update', '--resource-group', $rg, '--workspace-name', $logAnalytics, '--tags') + $commonTagValues + @('--retention-time', $Config.LogRetentionDays.ToString())
    $lawUpdateResult = Invoke-AzCli -Arguments $lawUpdateArgs
    OK $lawUpdateResult "Failed to update Log Analytics retention"
    Write-StepStatus "" "Success" "retention set to $($Config.LogRetentionDays) days"

    Write-StepStatus "Creating Container Apps environment" "Started" "2min"
    
    $acaStartTime = Get-Date
    $acaArgs = @('containerapp', 'env', 'create', '--name', $acaEnv, '--resource-group', $rg, '--location', $Region, '--logs-workspace-id', $lawCustomerId, '--logs-workspace-key', $lawPrimaryKey, '--tags') + $commonTagValues
    $acaCreateResult = Invoke-AzCli -Arguments $acaArgs
    OK $acaCreateResult "Failed to create Container Apps environment"
    $acaElapsed = [math]::Round(((Get-Date) - $acaStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$acaEnv (${acaElapsed}s)"

    Write-StepStatus "Creating Azure Container Registry" "Started" "25s"
    
    $acrStartTime = Get-Date
    $acrArgs = @('acr', 'create', '--resource-group', $rg, '--name', $acrName, '--sku', 'Basic', '--admin-enabled', 'false', '--tags') + $commonTagValues
    $acrResult = Invoke-AzCli -Arguments $acrArgs
    OK $acrResult "Failed to create Azure Container Registry"
    $acrElapsed = [math]::Round(((Get-Date) - $acrStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$acrName (${acrElapsed}s)"
    
    $acrLoginServerArgs = @('acr', 'show', '--resource-group', $rg, '--name', $acrName, '--query', 'loginServer', '--output', 'tsv')
    $acrLoginServerResult = Invoke-AzCli -Arguments $acrLoginServerArgs
    OK $acrLoginServerResult "Failed to retrieve ACR login server"
    $acrLoginServer = $acrLoginServerResult.TrimmedText
    
    Write-StepStatus "Building custom DAB image with baked config" "Started" "40s"
    
    $imageTag = "$acrLoginServer/dab-baked:$configHash"
    
    $buildStartTime = Get-Date
    $buildArgs = @('acr', 'build', '--resource-group', $rg, '--registry', $acrName, '--image', $imageTag, '--file', 'Dockerfile', '.')
    $buildResult = Invoke-AzCli -Arguments $buildArgs
    OK $buildResult "Failed to build custom DAB image"
    $buildElapsed = [math]::Round(((Get-Date) - $buildStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$imageTag (${buildElapsed}s)"
    
    $ContainerImage = $imageTag

    Write-StepStatus "Creating Container App with managed identity" "Started" "50s"
    
    $connectionString = "Server=tcp:${sqlServerFqdn},1433;Database=${sqlDb};Authentication=Active Directory Managed Identity;"
    
    $createAppStartTime = Get-Date
    $createAppArgs = @(
        'containerapp', 'create',
        '--name', $container,
        '--resource-group', $rg,
        '--environment', $acaEnv,
        '--system-assigned',
        '--registry-server', $acrLoginServer,
        '--registry-identity', 'system',
        '--ingress', 'external',
        '--target-port', '5000',
        '--image', $ContainerImage,
        '--cpu', $Config.ContainerCpu,
        '--memory', $Config.ContainerMemory,
        '--env-vars',
        "MSSQL_CONNECTION_STRING=$connectionString",
        "Runtime__ConfigFile=/App/dab-config.json",
        '--tags'
    ) + $commonTagValues
    
    $createAppResult = Invoke-AzCli -Arguments $createAppArgs
    OK $createAppResult "Failed to create Container App with ACR image"
    $createAppElapsed = [math]::Round(((Get-Date) - $createAppStartTime).TotalSeconds, 1)
    Write-StepStatus "" "Success" "$container (${createAppElapsed}s)"
    
    Write-StepStatus "Assigning AcrPull role to managed identity" "Started" "15s"
    
    $principalIdArgs = @('containerapp', 'show', '--name', $container, '--resource-group', $rg, '--query', 'identity.principalId', '--output', 'tsv')
    $principalIdResult = Invoke-AzCli -Arguments $principalIdArgs
    OK $principalIdResult "Failed to retrieve MI principal ID"
    $principalId = $principalIdResult.TrimmedText -replace 'WARNING:.*', '' -replace '\s+', ''
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        throw "Managed identity principal ID is empty or null"
    }
    if ($principalId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw "Managed identity principal ID is not a valid GUID. Got: '$principalId'"
    }
    
    Add-Content -Path $script:CliLog -Value "[$(Get-Date -Format o)] [INFO] Principal ID: $principalId"

    $acrIdArgs = @('acr', 'show', '--name', $acrName, '--resource-group', $rg, '--query', 'id', '--output', 'tsv')
    $acrIdResult = Invoke-AzCli -Arguments $acrIdArgs
    OK $acrIdResult "Failed to retrieve ACR resource ID"
    $acrId = $acrIdResult.TrimmedText -replace 'WARNING:.*', '' -replace '\s+', ' '
    $acrId = $acrId.Trim()
    
    $roleAssignArgs = @('role', 'assignment', 'create', '--assignee', $principalId, '--role', 'AcrPull', '--scope', $acrId)
    $roleAssignResult = Invoke-AzCli -Arguments $roleAssignArgs
    OK $roleAssignResult "Failed to assign AcrPull role"
    Write-StepStatus "" "Success" "AcrPull role assigned to $container MI"

    Write-StepStatus "Retrieving managed identity display name" "Started" "5s"
    
    try {
        $spDisplayName = Get-MI-DisplayName -PrincipalId $principalId
        Write-StepStatus "" "Success" "Retrieved: $spDisplayName"
    } catch {
        throw "Failed to retrieve managed identity display name: $($_.Exception.Message)"
    }

    $sqlUserName = $spDisplayName
    
    $sqlStartTime = Get-Date
    $retries = 0
    $maxRetries = 12
    $success = $false
    
    Write-StepStatus "Granting managed identity access to SQL Database" "Started" "10s"
    
    while (-not $success -and $retries -lt $maxRetries) {
        $retries++
        try {
            $escapedUserName = $sqlUserName.Replace("'", "''")
            $sqlQuery = @"
BEGIN TRY
    IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '$escapedUserName')
        CREATE USER [$sqlUserName] FROM EXTERNAL PROVIDER;
    ALTER ROLE db_datareader ADD MEMBER [$sqlUserName];
    ALTER ROLE db_datawriter ADD MEMBER [$sqlUserName];
    GRANT EXECUTE TO [$sqlUserName];
    SELECT 'PERMISSION_GRANT_SUCCESS' AS Result;
END TRY
BEGIN CATCH
    DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
    PRINT 'ERROR: Failed to grant permissions: ' + @ErrorMessage;
    THROW;
END CATCH
"@
            $sqlcmdOutput = sqlcmd -S $sqlServerFqdn -d $sqlDb -G -Q $sqlQuery 2>&1 | Out-String
            $sqlExit = $LASTEXITCODE
            
            # Check both exit code AND output for success message
            $success = $sqlExit -eq 0 -and $sqlcmdOutput -match 'PERMISSION_GRANT_SUCCESS'
            
            if (-not $success) {
                if ($sqlcmdOutput) {
                    Write-StepStatus "" "Info" "SQL output: $sqlcmdOutput"
                }
                if ($sqlExit -ne 0) {
                    Write-StepStatus "" "Info" "SQL exit code: $sqlExit"
                }
            }
        } catch {
            Write-StepStatus "" "Info" "SQL error: $($_.Exception.Message)"
            $success = $false
        }
        
        if (-not $success -and $retries -lt $maxRetries) {
            $baseWaitSeconds = [Math]::Min(240, 20 * [Math]::Pow(2, $retries - 1))
            $jitter = Get-Random -Minimum 1 -Maximum 6
            $waitSeconds = $baseWaitSeconds + $jitter
            Write-StepStatus "" "Retrying" "attempt ${retries}/${maxRetries}, waiting ${waitSeconds}s"
            Wait-Seconds $waitSeconds "SQL MI propagation"
        }
    }
    
    if (-not $success) {
        $sqlElapsed = [math]::Round(((Get-Date) - $sqlStartTime).TotalSeconds, 0)
        Write-StepStatus "" "Error" "Failed after $maxRetries attempts (${sqlElapsed}s, exit code: $sqlExit)"
        throw "Failed to grant SQL access after $maxRetries attempts. MI may not be propagated to SQL Server's Entra cache (exit code: $sqlExit)" 
    }
    
    $sqlElapsed = [math]::Round(((Get-Date) - $sqlStartTime).TotalSeconds, 0)
    Write-StepStatus "" "Success" "$sqlUserName granted access to $sqlDb (${sqlElapsed}s)"
    
    Write-StepStatus "Verifying SQL permissions" "Started" "5s"
    $verifyStartTime = Get-Date
    
    try {
        $verifyPermsQuery = @"
SELECT 
    dp.name AS PrincipalName,
    dp.type_desc AS PrincipalType,
    CASE 
        WHEN EXISTS (SELECT 1 FROM sys.database_role_members drm 
                     JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id 
                     WHERE drm.member_principal_id = dp.principal_id AND r.name = 'db_datareader') 
        THEN 'YES' ELSE 'NO' END AS HasDataReader,
    CASE 
        WHEN EXISTS (SELECT 1 FROM sys.database_role_members drm 
                     JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id 
                     WHERE drm.member_principal_id = dp.principal_id AND r.name = 'db_datawriter') 
        THEN 'YES' ELSE 'NO' END AS HasDataWriter,
    CASE 
        WHEN EXISTS (SELECT 1 FROM sys.database_permissions p 
                     WHERE p.grantee_principal_id = dp.principal_id 
                     AND p.permission_name = 'EXECUTE' 
                     AND p.state_desc = 'GRANT') 
        THEN 'YES' ELSE 'NO' END AS HasExecute
FROM sys.database_principals dp
WHERE dp.name = '$escapedUserName';
"@
        
        $verifyOutput = sqlcmd -S $sqlServerFqdn -d $sqlDb -G -Q $verifyPermsQuery -h -1 -W 2>&1 | Out-String
        $verifyExit = $LASTEXITCODE
        
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $script:CliLog -Value "[$timestamp] [INFO] Permission verification for $sqlUserName`n$verifyOutput`n"
        
        if ($verifyExit -eq 0) {
            $hasExecute = $verifyOutput -match 'YES\s+YES\s+YES'
            
            if ($hasExecute) {
                $verifyElapsed = [math]::Round(((Get-Date) - $verifyStartTime).TotalSeconds, 1)
                Write-StepStatus "" "Success" "db_datareader + db_datawriter + EXECUTE verified for $sqlUserName (${verifyElapsed}s)"
            } else {
                $verifyElapsed = [math]::Round(((Get-Date) - $verifyStartTime).TotalSeconds, 1)
                Write-StepStatus "" "Info" "Permissions granted but verification pattern incomplete (${verifyElapsed}s)"
            }
        } else {
            $verifyElapsed = [math]::Round(((Get-Date) - $verifyStartTime).TotalSeconds, 1)
            Write-StepStatus "" "Info" "Verification query failed, but grants succeeded (${verifyElapsed}s)"
        }
    } catch {
        Write-StepStatus "" "Info" "Permission verification skipped: $($_.Exception.Message)"
    }
    
    $restartStartTime = Get-Date
    Write-StepStatus "Restarting container to activate managed identity" "Started" "5s"
    
    $revisionNameArgs = @('containerapp', 'revision', 'list', '--name', $container, '--resource-group', $rg, '--query', '[0].name', '--output', 'tsv')
    $revisionNameResult = Invoke-AzCli -Arguments $revisionNameArgs
    OK $revisionNameResult "Failed to retrieve revision name"
    $revisionName = $revisionNameResult.TrimmedText
    
    $restartArgs = @('containerapp', 'revision', 'restart', '--name', $container, '--resource-group', $rg, '--revision', $revisionName)
    $restartResult = Invoke-AzCli -Arguments $restartArgs
    
    if ($restartResult.ExitCode -eq 0) {
        $restartElapsed = [math]::Round(((Get-Date) - $restartStartTime).TotalSeconds, 0)
        Write-StepStatus "" "Success" "$container restarted (${restartElapsed}s)"
    } else {
        $restartElapsed = [math]::Round(((Get-Date) - $restartStartTime).TotalSeconds, 0)
        Write-StepStatus "" "Error" "Container failed to restart (${restartElapsed}s, exit code: $($restartResult.ExitCode))"
        throw "Failed to restart container: $($restartResult.Text)"
    }
    
    Write-StepStatus "Verifying container is running" "Started" "5min"
    $containerRunning = $false
    $maxWaitMinutes = 5
    $checkDeadline = (Get-Date).AddMinutes($maxWaitMinutes)
    $checkAttempt = 0
    $verifyStartTime = Get-Date
    
    while (-not $containerRunning -and (Get-Date) -lt $checkDeadline) {
        $checkAttempt++
        Start-Sleep -Seconds 10
        
        $statusArgs = @('containerapp', 'show', '--name', $container, '--resource-group', $rg, '--query', '{provisioning:properties.provisioningState,running:properties.runningStatus}', '--output', 'json')
        $statusResult = Invoke-AzCli -Arguments $statusArgs
        
        if ($statusResult.ExitCode -eq 0) {
            # Sanitize WARNING text from containerapp extension before parsing JSON
            $cleanedJson = $statusResult.TrimmedText -replace '(?m)^WARNING:.*$', ''
            $cleanedJson = $cleanedJson.Trim()
            
            if (-not [string]::IsNullOrWhiteSpace($cleanedJson)) {
                $status = $cleanedJson | ConvertFrom-Json
            
                if ($status.provisioning -eq 'Succeeded' -and $status.running -eq 'Running') {
                    $replicaArgs = @('containerapp', 'replica', 'list', '--name', $container, '--resource-group', $rg, '--query', '[0].properties.containers[0].restartCount', '--output', 'tsv')
                    $replicaResult = Invoke-AzCli -Arguments $replicaArgs
                
                    if ($replicaResult.ExitCode -eq 0) {
                        # Remove WARNING lines and extract numeric value
                        $restartCountRaw = $replicaResult.TrimmedText
                        $restartCount = ($restartCountRaw -split "`n" | Where-Object { $_ -match '^\d+$' }) | Select-Object -First 1
                        
                        if (-not $restartCount) { $restartCount = 0 }
                        [int]$restartCount = $restartCount
                    
                        if ($restartCount -lt 3) {
                            $containerRunning = $true
                            $verifyElapsed = [math]::Round(((Get-Date) - $verifyStartTime).TotalSeconds, 1)
                            Write-StepStatus "" "Success" "$container running with restart count $restartCount (${verifyElapsed}s)"
                        } else {
                            Write-StepStatus "" "Info" "Container in crash loop (restart count: $restartCount)"
                        }
                    }
                }
            }
        }
    }
    
    if (-not $containerRunning) {
        $logsArgs = @('containerapp', 'logs', 'show', '--name', $container, '--resource-group', $rg, '--tail', '50')
        $logsResult = Invoke-AzCli -Arguments $logsArgs
        $logOutput = if ($logsResult.TrimmedText) { $logsResult.TrimmedText } else { "No logs available" }
        throw "Container did not reach Running state within $maxWaitMinutes minutes. Recent logs:`n$logOutput"
    }

    $containerShowArgs = @('containerapp', 'show', '--name', $container, '--resource-group', $rg, '--query', 'properties.configuration.ingress.fqdn', '--output', 'tsv')
    $containerShowResult = Invoke-AzCli -Arguments $containerShowArgs
    if ($containerShowResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($containerShowResult.TrimmedText)) {
        # Remove WARNING lines from Azure CLI containerapp extension before constructing URL
        $cleanFqdn = ($containerShowResult.TrimmedText -split "`n" | Where-Object { $_ -notmatch '^WARNING:' }) -join ''
        $cleanFqdn = $cleanFqdn.Trim()
        $containerUrl = "https://$cleanFqdn"
        
        Write-StepStatus "Checking DAB API health endpoint" "Started" "2min"
        $healthCheckStartTime = Get-Date
        
        # Give container time to stabilize after restart
        Write-Host "  Waiting 15s for container to stabilize..." -ForegroundColor Gray
        Start-Sleep -Seconds 15
        
        $healthAttempts = 10
        $waitBetweenRetries = 15
        $healthCheckPassed = $false
        
        for ($healthRetry = 1; $healthRetry -le $healthAttempts; $healthRetry++) {
            try {
                $healthUrl = "$containerUrl/health"
                $healthResponse = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 10 -ErrorAction Stop
                
                if ($healthResponse.status -eq "Healthy") {
                    $healthElapsed = [math]::Round(((Get-Date) - $healthCheckStartTime).TotalSeconds, 1)
                    Write-StepStatus "" "Success" "DAB API health: Healthy (${healthElapsed}s)"
                    $healthCheckPassed = $true
                    break
                } elseif ($healthResponse.status -eq "Unhealthy") {
                    $dbCheck = $healthResponse.checks | Where-Object { $_.tags -contains "data-source" } | Select-Object -First 1
                    if ($dbCheck -and $dbCheck.status -eq "Healthy") {
                        $healthElapsed = [math]::Round(((Get-Date) - $healthCheckStartTime).TotalSeconds, 1)
                        Write-StepStatus "" "Success" "DAB API responding, database connection healthy (${healthElapsed}s)"
                        $healthCheckPassed = $true
                        break
                    } else {
                        if ($healthRetry -lt $healthAttempts) {
                            Write-StepStatus "" "Retrying" "health status: $($healthResponse.status), attempt $healthRetry/$healthAttempts, waiting ${waitBetweenRetries}s"
                            Start-Sleep -Seconds $waitBetweenRetries
                        } else {
                            Write-StepStatus "" "Info" "health status: $($healthResponse.status) after $healthAttempts attempts - database may need verification"
                        }
                    }
                } else {
                    if ($healthRetry -lt $healthAttempts) {
                        Write-StepStatus "" "Retrying" "health status: $($healthResponse.status), attempt $healthRetry/$healthAttempts, waiting ${waitBetweenRetries}s"
                        Start-Sleep -Seconds $waitBetweenRetries
                    }
                }
            } catch {
                if ($healthRetry -lt $healthAttempts) {
                    Write-StepStatus "" "Retrying" "unable to reach health endpoint, attempt $healthRetry/$healthAttempts, waiting ${waitBetweenRetries}s"
                    Start-Sleep -Seconds $waitBetweenRetries
                } else {
                    $healthElapsed = [math]::Round(((Get-Date) - $healthCheckStartTime).TotalSeconds, 1)
                    Write-StepStatus "" "Info" "Unable to verify DAB API health after $healthAttempts attempts (${healthElapsed}s)"
                    Write-Host "  Health endpoint: $healthUrl" -ForegroundColor DarkGray
                    Write-Host "  Container may still be starting - check logs if needed" -ForegroundColor DarkGray
                }
            }
        }
        
        if (-not $healthCheckPassed) {
            Write-StepStatus "" "Info" "Health not yet Healthy; continuing"
        }
    } else {
        $containerUrl = "Not available (ingress not configured)"
        $ingressMessage = if ($containerShowResult.TrimmedText) { $containerShowResult.TrimmedText } else { "Container ingress not ready" }
        Write-StepStatus "" "Info" $ingressMessage
    }

    $totalTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
    $totalTimeFormatted = "${totalTime}m"

    Write-DeploymentSummary -ResourceGroup $rg -Region $Region -SqlServer $sqlServer -SqlDatabase $sqlDb `
        -Container $container -ContainerUrl $containerUrl -LogAnalytics $logAnalytics `
        -Environment $acaEnv -CurrentUser $currentUserName -DatabaseType $dbType -TotalTime $totalTimeFormatted `
        -ClientIp $clientIp -SqlServerFqdn $sqlServerFqdn `
        -FirewallRuleName $firewallRuleName

    $deploymentSummary = @{
        ResourceGroup = $rg
        SubscriptionName = $currentSub
        Region = $Region
        Timestamp = $runTimestamp
        Version = $Version
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        Resources = @{
            SqlServer = $sqlServer
            Database = $sqlDb
            ContainerApp = $container
            ContainerUrl = $containerUrl
            LogAnalytics = $logAnalytics
            Environment = $acaEnv
        }
        DeploymentTime = $totalTimeFormatted
        CurrentUser = $currentUserName
        Tags = @{
            author = 'dab-deploy-demo-script'
            version = $Version
            owner = $ownerTagValue
        }
    }
    
    # Append deployment summary to log file
    $summaryJson = $deploymentSummary | ConvertTo-Json -Depth 3
    Add-Content -Path $script:CliLog -Value "`n`n[DEPLOYMENT SUMMARY]"
    Add-Content -Path $script:CliLog -Value $summaryJson
    
    Write-Host "`nDeployment log saved to: $script:CliLog" -ForegroundColor Green

} catch {
    Write-Host "`n"
    Write-Host ("=" * 85) -ForegroundColor Red
    Write-Host "DEPLOYMENT FAILED - ROLLING BACK" -ForegroundColor Red -BackgroundColor Black
    Write-Host ("=" * 85) -ForegroundColor Red
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $script:CliLog -Value "[$timestamp] [ERR] DEPLOYMENT FAILED`n$($_.Exception.Message)`n$($_.ScriptStackTrace)`n"
    
    if (-not $NoCleanup -and $rg) {
        Write-Host "`nCleaning up partial deployment..." -ForegroundColor Yellow
        
        $deleteArgs = @('group', 'delete', '--name', $rg, '--yes', '--no-wait')
        $deleteResult = Invoke-AzCli -Arguments $deleteArgs
        
        if ($deleteResult.ExitCode -eq 0) {
            Write-Host "Resource group deletion initiated (running in background): $rg" -ForegroundColor Green
        } else {
            Write-Host "WARNING: Failed to delete resource group automatically" -ForegroundColor Red
            Write-Host "Manual cleanup required: az group delete -n $rg -y" -ForegroundColor Yellow
            Write-Host "Error: $($deleteResult.Text)" -ForegroundColor DarkYellow
        }
    } elseif ($NoCleanup) {
        Write-Host "`nSkipping cleanup (-NoCleanup specified)" -ForegroundColor Yellow
        Write-Host "Resource group preserved for debugging: $rg" -ForegroundColor Cyan
    }
    
    Write-Host "`nDeployment log available at: $script:CliLog" -ForegroundColor Cyan
    
    throw
} finally {
    $ErrorActionPreference = 'Continue'
    Write-Host "`nScript completed at $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan
}

Write-Host "`n================================================================================" -ForegroundColor Green
Write-Host "  ✓ DEPLOYMENT SUCCESSFUL" -ForegroundColor Green
Write-Host "================================================================================" -ForegroundColor Green
Write-Host ""

exit 0