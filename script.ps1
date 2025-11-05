# Deploy Data API Builder with Azure SQL Database and Container Apps
# 
# Parameters:
#   -Region: Azure region for deployment (default: westus2)
#   -ContainerImage: DAB container image to deploy (default: mcr.microsoft.com/azure-databases/data-api-builder:1.7.75-rc)
#   -DatabasePath: Path to SQL database file - local or relative from script root (default: ./database.sql)
#   -ConfigPath: Path to DAB config file - local or relative from script root (default: ./dab-config.json)
#   -NoBrowser: Skip opening Azure Portal after deployment (useful for CI/CD)
#   -Diagnostics: Enable verbose Azure CLI output (sets AZURE_CORE_ONLY_SHOW_ERRORS=0, AZURE_CLI_DIAGNOSTICS=1)
#
# Examples:
#   .\script.ps1
#   .\script.ps1 -Region eastus
#   .\script.ps1 -Region westeurope -DatabasePath ".\databases\prod.sql" -ConfigPath ".\configs\prod.json"
#   .\script.ps1 -NoBrowser  # CI/CD mode
#   .\script.ps1 -Diagnostics  # Full Azure CLI JSON output for troubleshooting
#
param(
    [string]$Region = "westus2",
    [string]$ContainerImage = "mcr.microsoft.com/azure-databases/data-api-builder:1.7.75-rc",
    [string]$DatabasePath = "./database.sql",
    [string]$ConfigPath = "./dab-config.json",
    [switch]$NoBrowser,
    [switch]$Diagnostics
)

# Script version (for git-tracked repos, use: git describe --tags --abbrev=0)
$Version = "0.0.1"

# Enable strict mode for better error detection
Set-StrictMode -Version Latest

# Validate region (common regions known to support all required services)
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

# Configure Azure CLI output based on diagnostics flag
if ($Diagnostics) {
    Write-Host "Diagnostics mode enabled: Full Azure CLI output will be displayed" -ForegroundColor Cyan
    # Remove the "only show errors" setting to see all output
    $env:AZURE_CORE_ONLY_SHOW_ERRORS = "0"
    # Enable verbose output from Azure CLI
    $env:AZURE_CLI_DIAGNOSTICS = "1"
} else {
    # Configure Azure CLI defaults to reduce noise
    $env:AZURE_CORE_ONLY_SHOW_ERRORS = "1"
}

# Configuration constants
$Config = @{
    SqlRetryAttempts = 3
    SqlRetryDelaySec = 15
    PropagationWaitSec = 30
    LogRetentionDays = 90
    ContainerCpu = "0.5"
    ContainerMemory = "1.0Gi"
    StorageShareQuotaGb = 1
}

$ErrorActionPreference = 'Stop'
$startTime = Get-Date
$runTimestamp = Get-Date -Format "yyyyMMddHHmmss"

# Start transcript for audit trail
$transcriptPath = "dab-deploy-$runTimestamp.log"
Start-Transcript -Path $transcriptPath -Append | Out-Null

Write-Host "dab-deploy-demo version $Version" -ForegroundColor Cyan
Write-Host ""

# Validate and install dependencies
Write-Host "Checking prerequisites..." -ForegroundColor Cyan

# Check Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "  Azure CLI: " -NoNewline -ForegroundColor Yellow
    Write-Host "Not installed" -ForegroundColor Red
    Write-Host ""
    Write-Host "Azure CLI is required but not installed." -ForegroundColor Yellow
    Write-Host "Please install from: https://aka.ms/installazurecliwindows" -ForegroundColor White
    Write-Host "After installation, restart your terminal and run this script again." -ForegroundColor White
    throw "Azure CLI is not installed"
} else {
    # Performance: Single JSON parse instead of double query
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
# Check and install sqlcmd
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    Write-Host "  sqlcmd: " -NoNewline -ForegroundColor Yellow
    Write-Host "Not installed" -ForegroundColor Red
    Write-Host ""
    Write-Host "Attempting to install SQL Server command-line tools via winget..." -ForegroundColor Cyan
    
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            # Install SQL Server command-line tools using winget (2022 CU is the current package)
            winget install Microsoft.SqlServer.2022.CU --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
            
            # Refresh PATH to pick up newly installed sqlcmd
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
    Write-Host "Installed" -ForegroundColor Green
}
Write-Host ""

# CRITICAL: Always run az login to ensure correct user context
Write-Host "Authenticating to Azure..." -ForegroundColor Cyan
Write-Host "This ensures you're using the correct Azure account and tenant." -ForegroundColor Gray
Write-Host ""

try {
    # Run az login interactively - this opens browser for user to select account
    az login --output none 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Azure login failed"
    }
    Write-Host "Azure authentication successful" -ForegroundColor Green
    Write-Host ""
} catch {
    Write-Host "Azure authentication failed" -ForegroundColor Red
    Write-Host "Please ensure you have access to an Azure subscription and try again." -ForegroundColor Yellow
    throw "Azure authentication failed: $($_.Exception.Message)"
}

# Validate required files before starting
Write-Host "Validating required files..." -ForegroundColor Cyan

# Check database.sql exists
if (-not (Test-Path $DatabasePath)) {
    Write-Host "ERROR: database.sql not found at: $DatabasePath" -ForegroundColor Red
    Write-Host "Please create a database.sql file with your database schema and try again." -ForegroundColor Yellow
    Write-Host "Or specify a custom path: -DatabasePath <path>" -ForegroundColor Cyan
    throw "database.sql not found at: $DatabasePath"
}

# Check database.sql is not empty
$databaseContent = Get-Content $DatabasePath -Raw -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($databaseContent)) {
    Write-Host "ERROR: database.sql is empty at: $DatabasePath" -ForegroundColor Red
    Write-Host "The database script file is empty. Please add SQL commands to create your database." -ForegroundColor Yellow
    Write-Host "Example content:" -ForegroundColor Cyan
    Write-Host "  CREATE TABLE dbo.MyTable (Id INT PRIMARY KEY, Name NVARCHAR(100));" -ForegroundColor White
    throw "database.sql is empty at: $DatabasePath"
}
Write-Host "  database.sql: Found and contains content" -ForegroundColor Green

# Check dab-config.json exists
if (-not (Test-Path $ConfigPath)) {
    Write-Host "ERROR: dab-config.json not found at: $ConfigPath" -ForegroundColor Red
    Write-Host "Please create a dab-config.json file with your Data API Builder configuration and try again." -ForegroundColor Yellow
    Write-Host "Or specify a custom path: -ConfigPath <path>" -ForegroundColor Cyan
    throw "dab-config.json not found at: $ConfigPath"
}

# Validate dab-config.json has correct connection string environment variable reference
try {
    $configContent = Get-Content $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $connectionStringRef = $configContent.'data-source'.'connection-string'
    
    # The script sets MSSQL_CONNECTION_STRING, so config must reference it
    $expectedEnvVar = "MSSQL_CONNECTION_STRING"
    $expectedRef = "@env('$expectedEnvVar')"
    
    if ($connectionStringRef -ne $expectedRef) {
        Write-Host "ERROR: dab-config.json has incorrect connection string reference" -ForegroundColor Red
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
    Write-Host "  dab-config.json: Connection string reference validated ($expectedRef)" -ForegroundColor Green
} catch {
    Write-Host "ERROR: Failed to parse dab-config.json at: $ConfigPath" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Please ensure the file contains valid JSON syntax." -ForegroundColor White
    throw "Failed to parse or validate dab-config.json: $($_.Exception.Message)"
}

Write-Host ""

# Detect VS Code terminal (limited ANSI support)
function Test-IsVsCodeHost {
    try {
        return $Host.Name -eq 'Visual Studio Code Host' -or
               $env:TERM_PROGRAM -eq 'vscode' -or
               ($Host -and $Host.GetType().FullName -match 'EditorServices')
    } catch {
        return $false
    }
}

$script:IsVsCode = Test-IsVsCodeHost
$script:UseLiveProgress = -not $script:IsVsCode

if ($script:IsVsCode) {
    Write-Host "VS Code terminal detected — using simplified progress display" -ForegroundColor DarkYellow
}

# Heartbeat spinner for long operations in VS Code
function Start-Heartbeat {
    param(
        [string]$Message = "Working...",
        [int]$IntervalSec = 1
    )
    if ($script:UseLiveProgress) { return }  # Only for VS Code
    
    $script:__heartbeatStart = Get-Date
    $global:__heartbeatJob = Start-Job {
        param($Message, $IntervalSec, $Start)
        $chars = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
        $i = 0
        while ($true) {
            $elapsed = [int]((Get-Date) - $Start).TotalSeconds
            $spinner = $chars[$i % $chars.Length]
            Write-Host "`r$Message $spinner  (${elapsed}s elapsed)" -NoNewline -ForegroundColor DarkCyan
            Start-Sleep -Seconds $IntervalSec
            $i++
        }
    } -ArgumentList $Message, $IntervalSec, $script:__heartbeatStart
}

function Stop-Heartbeat {
    if ($global:__heartbeatJob) {
        Stop-Job $global:__heartbeatJob -Force | Out-Null
        Remove-Job $global:__heartbeatJob -Force | Out-Null
        Write-Host "`r" -NoNewline
        $global:__heartbeatJob = $null
    }
}

# Global variable to track current operation for error reporting
$script:CurrentOperation = ""
$script:CurrentOperationMessage = ""
$script:ProgressRows = @{}
$script:ProgressSteps = @()
$esc = [char]27

function Set-CurrentOperation {
    param(
        [string]$Step,
        [string]$Message
    )
    $script:CurrentOperation = $Step
    $script:CurrentOperationMessage = $Message
}

function Clear-CurrentOperation {
    $script:CurrentOperation = ""
    $script:CurrentOperationMessage = ""
}

function Initialize-ProgressUI {
    <#
    .SYNOPSIS
    Initializes Docker-style live progress UI with all deployment steps.
    
    .DESCRIPTION
    Creates a fixed table of all deployment steps with initial "Not Started" status.
    Each step occupies one line and will be updated in place using ANSI cursor control.
    In VS Code, falls back to simple text output.
    #>
    param([string[]]$Steps)
    
    $script:ProgressSteps = $Steps
    
    # VS Code fallback: just list steps without live UI
    if (-not $script:UseLiveProgress) {
        Write-Host ""
        Write-Host "Deployment Steps:" -ForegroundColor Cyan
        foreach ($step in $Steps) {
            Write-Host "  • $step" -ForegroundColor DarkGray
        }
        Write-Host ""
        return
    }
    
    # Full live progress UI for Windows Terminal
    Write-Host ""
    Write-Host "Deployment Progress:" -ForegroundColor Cyan
    Write-Host ("=" * 100) -ForegroundColor DarkCyan
    
    $top = [Console]::CursorTop
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $step = $Steps[$i]
        $script:ProgressRows[$step] = $top + $i
        $paddedStep = $step.PadRight(60)
        Write-Host "$paddedStep [                      ] Not Started"
    }
    
    Write-Host ("=" * 100) -ForegroundColor DarkCyan
    Write-Host ""
}

function Update-ProgressUI {
    <#
    .SYNOPSIS
    Updates a specific deployment step with new status in place.
    
    .DESCRIPTION
    Uses ANSI escape sequences to move cursor to the step's line and redraw
    the progress bar and status without scrolling the console.
    
    .PARAMETER Step
    The deployment step to update (must match Initialize-ProgressUI step name)
    
    .PARAMETER Status
    Current status: Starting, Progress, Success, Error, Warning
    
    .PARAMETER Extra
    Additional information like resource name or error message
    
    .PARAMETER ElapsedTime
    Optional elapsed time in seconds
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Step,
        
        [ValidateSet("Starting","Progress","Success","Error","Warning")]
        [string]$Status,
        
        [string]$Extra = "",
        
        [double]$ElapsedTime = 0
    )

    # VS Code fallback: simple text output
    if (-not $script:UseLiveProgress) {
        $statusText = switch ($Status) {
            "Starting" { "Starting..." }
            "Progress" { "In Progress..." }
            "Success"  { 
                if ($ElapsedTime -gt 0) { "✓ $Extra ($($ElapsedTime)s)" }
                elseif ($Extra) { "✓ $Extra" }
                else { "✓ Complete" }
            }
            "Warning"  { "⚠ $Extra" }
            "Error"    { "✗ Error: $Extra" }
        }
        
        $color = switch ($Status) {
            "Starting" { "Yellow" }
            "Progress" { "Cyan" }
            "Success"  { "Green" }
            "Warning"  { "Yellow" }
            "Error"    { "Red" }
        }
        
        Write-Host "$Step : $statusText" -ForegroundColor $color
        return
    }

    if (-not $script:ProgressRows.ContainsKey($Step)) { return }
    
    # Save current cursor position
    $currentRow = [Console]::CursorTop
    $targetRow = $script:ProgressRows[$Step]
    
    # Move cursor up to target row
    $moveUp = $currentRow - $targetRow
    if ($moveUp -gt 0) { 
        Write-Host -NoNewline "$esc[${moveUp}A" 
    }
    
    # Move cursor to start of line
    Write-Host -NoNewline "`r"
    
    # Build progress bar based on status
    $bar = switch ($Status) {
        "Starting" { "[=====>                ]" }
        "Progress" { "[==============>       ]" }
        "Success"  { "[======================]" }
        "Warning"  { "[=======!==============]" }
        "Error"    { "[========X=============]" }
    }
    
    # Choose color
    $color = switch ($Status) {
        "Starting" { "Yellow" }
        "Progress" { "Cyan" }
        "Success"  { "Green" }
        "Warning"  { "Yellow" }
        "Error"    { "Red" }
    }
    
    # Build status text
    $statusText = switch ($Status) {
        "Starting" { "Starting" }
        "Progress" { "In Progress" }
        "Success"  { 
            if ($ElapsedTime -gt 0) { "$Extra ($($ElapsedTime)s)" }
            else { $Extra }
        }
        "Warning"  { $Extra }
        "Error"    { "Error: $Extra" }
    }
    
    # Pad step name and status text to fixed widths
    $paddedStep = $Step.PadRight(60)
    $paddedStatus = $statusText.PadRight(35)
    
    # Write the complete line
    Write-Host -NoNewline $paddedStep
    Write-Host -NoNewline " $bar "
    Write-Host $paddedStatus -ForegroundColor $color
    
    # Move cursor back to bottom
    if ($moveUp -gt 0) {
        Write-Host -NoNewline "$esc[${moveUp}B"
    }
}

function Write-Progress-Step {
    <#
    .SYNOPSIS
    Compatibility wrapper for Update-ProgressUI that maintains old function signature.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [ValidateSet("NotStarted", "Starting", "Progress", "Success", "Warning", "Info", "Error")]
        [string]$Status = "Starting",
        
        [string]$ResourceName = "",
        
        [double]$ElapsedTime = $null
    )
    
    # Map to new function
    if ($Status -eq "Info") {
        # Info messages print directly
        Write-Host "  $Message" -ForegroundColor Gray
    } else {
        Update-ProgressUI -Step $Message -Status $Status -Extra $ResourceName -ElapsedTime $ElapsedTime
    }
}

function Get-SimplifiedError {
    <#
    .SYNOPSIS
    Simplifies Azure CLI error messages into user-friendly guidance.
    #>
    param([string]$ErrorMessage)
    
    # Common error patterns and their simplifications (order matters!)
    # Check syntax/parameter errors FIRST before fuzzy keyword matches
    if ($ErrorMessage -match "unrecognized arguments.*--tags") {
        return "CLI version doesn't support --tags on this command. Tags will be applied separately with update command."
    }
    if ($ErrorMessage -match "unrecognized arguments") {
        return "Invalid parameter or CLI version mismatch. Check command syntax and Azure CLI version."
    }
    if ($ErrorMessage -match "unrecognized arguments.*--logs-key") {
        return "Wrong parameter name. Use --logs-workspace-key (not --logs-key)."
    }
    if ($ErrorMessage -match "Supply the --logs-key associated with the --logs-customer-id") {
        return "Missing Log Analytics workspace key. This has been fixed - please retry."
    }
    if ($ErrorMessage -match "already exists") {
        return "Resource already exists. Try using a different region or delete existing resources."
    }
    if ($ErrorMessage -match "quota|limit") {
        return "Resource quota exceeded. Try a different region or contact Azure support."
    }
    if ($ErrorMessage -match "not found|does not exist") {
        return "Resource not found. It may not have been created yet or was deleted."
    }
    if ($ErrorMessage -match "unauthorized|forbidden|permission") {
        return "Permission denied. Ensure you have required Azure permissions (Contributor or Owner)."
    }
    if ($ErrorMessage -match "authentication|token") {
        return "Authentication failed. Run 'az login' and retry."
    }
    if ($ErrorMessage -match "timeout|timed out") {
        return "Operation timed out. Azure may be experiencing delays - please retry."
    }
    # Network check LAST (since AI examples may contain "connection" keyword)
    if ($ErrorMessage -match "network|connection" -and $ErrorMessage -notmatch "Examples from AI knowledge base") {
        return "Network connectivity issue. Check your internet connection and retry."
    }
    
    # If no pattern matches, try to extract the most relevant line
    $lines = $ErrorMessage -split "`n" | Where-Object { $_ -match "ERROR:" -or $_ -match "error:" } | Select-Object -First 1
    if ($lines) {
        return $lines.Trim()
    }
    
    # Last resort: return first 200 characters
    if ($ErrorMessage.Length -gt 200) {
        return $ErrorMessage.Substring(0, 200) + "..."
    }
    
    return $ErrorMessage
}

function Assert-Success {
    <#
    .SYNOPSIS
    Validates Azure CLI command exit codes and throws detailed errors on failure.
    
    .DESCRIPTION
    Checks if an Azure CLI command succeeded (exit code 0) and throws a formatted
    exception with the command output if it failed. Used throughout the script to
    ensure robust error handling. Automatically updates the progress display with
    the error message.
    
    .PARAMETER ExitCode
    The exit code from the Azure CLI command ($LASTEXITCODE or result.ExitCode)
    
    .PARAMETER Message
    Descriptive error message to display if the command failed
    
    .PARAMETER CommandOutput
    The command's stdout/stderr output to include in the error details
    
    .EXAMPLE
    Assert-Success -ExitCode $result.ExitCode -Message "Failed to create resource group" -CommandOutput $result.Text
    #>
    param(
        [int]$ExitCode,
        [string]$Message,
        $CommandOutput
    )

    if ($ExitCode -ne 0) {
        # Update progress display with error
        if ($script:CurrentOperationMessage) {
            $simplifiedError = Get-SimplifiedError -ErrorMessage $CommandOutput
            Update-ProgressUI -Step $script:CurrentOperationMessage -Status "Error" -Extra $simplifiedError
        }
        
        $formattedOutput = if ($CommandOutput) { ($CommandOutput | Out-String).Trim() } else { "Exit code: $ExitCode" }
        throw "$Message`n$formattedOutput"
    }
}

function Test-AzureTokenExpiry {
    <#
    .SYNOPSIS
    Checks if Azure access token is expired or about to expire, refreshes if needed.
    
    .DESCRIPTION
    Long-running deployments (>60 minutes) can hit token expiry mid-execution.
    This function checks token expiry and refreshes via az login if needed.
    #>
    param(
        [int]$ExpiryBufferMinutes = 5  # Refresh if token expires within 5 minutes
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

function Invoke-AzCli {
    <#
    .SYNOPSIS
    Wrapper for Azure CLI commands that captures exit codes and output reliably.
    
    .DESCRIPTION
    Executes Azure CLI commands using PowerShell's call operator (&) to properly
    capture $LASTEXITCODE. Returns a custom object with exit code, raw output,
    and formatted text for consistent error handling throughout the script.
    
    When -Diagnostics is enabled, prints full command and JSON output for debugging.
    
    .PARAMETER Arguments
    Array of arguments to pass to the az command (e.g., @('group', 'list', '--output', 'json'))
    
    .OUTPUTS
    PSCustomObject with properties: ExitCode, Output, Text, TrimmedText
    
    .EXAMPLE
    $result = Invoke-AzCli -Arguments @('group', 'create', '--name', 'mygroup', '--location', 'eastus')
    Assert-Success -ExitCode $result.ExitCode -Message "Failed to create group" -CommandOutput $result.Text
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    # Diagnostics: Print the full command being executed
    if ($Diagnostics) {
        Write-Host "`n[DIAGNOSTICS] Azure CLI Command:" -ForegroundColor Magenta
        Write-Host "  az $($Arguments -join ' ')" -ForegroundColor DarkGray
    }

    $output = & az @Arguments 2>&1
    $exitCode = $global:LASTEXITCODE
    $text = $output | Out-String

    # Diagnostics: Print full raw output
    if ($Diagnostics) {
        Write-Host "[DIAGNOSTICS] Exit Code: $exitCode" -ForegroundColor Magenta
        Write-Host "[DIAGNOSTICS] Raw Output:" -ForegroundColor Magenta
        Write-Host $text -ForegroundColor DarkGray
    }

    [pscustomobject]@{
        ExitCode    = $exitCode
        Output      = $output
        Text        = $text
        TrimmedText = $text.Trim()
    }
}

# Show a spinner while a command is running
function Start-ActivityIndicator {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )
    
    $spinnerChars = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
    $spinnerIndex = 0
    $maxMessageWidth = 60
    
    $displayMessage = if ($Message.Length -gt $maxMessageWidth) {
        $Message.Substring(0, $maxMessageWidth - 3) + "..."
    } else {
        $Message.PadRight($maxMessageWidth)
    }
    
    # Start a background job to run the script
    $job = Start-Job -ScriptBlock $ScriptBlock
    
    # Show spinner while job is running
    $progressBar = "[==============>       ]"
    while ($job.State -eq 'Running') {
        $spinner = $spinnerChars[$spinnerIndex % $spinnerChars.Length]
        Write-Host "`r$displayMessage $progressBar $spinner " -NoNewline -ForegroundColor DarkCyan
        $spinnerIndex++
        Start-Sleep -Milliseconds 100
    }
    
    # Get the result
    $result = Receive-Job -Job $job -Wait -AutoRemoveJob
    
    return $result
}

# Enhanced countdown function with Docker-style progress bar
function Start-CountdownSleep($Seconds, $Reason, $ResourceName = "") {
    $maxMessageWidth = 60
    $displayMessage = if ($Reason.Length -gt $maxMessageWidth) {
        $Reason.Substring(0, $maxMessageWidth - 3) + "..."
    } else {
        $Reason.PadRight($maxMessageWidth)
    }
    
    $totalSeconds = $Seconds
    $progressBar = "[======================]"
    
    # Show starting state
    try { [Console]::CursorLeft = 0 } catch { }
    Write-Host "`r$displayMessage $progressBar" -NoNewline -ForegroundColor DarkCyan
    Write-Host " $Seconds seconds" -NoNewline -ForegroundColor Yellow
    Write-Host ""
    
    # Use 1-second intervals for smooth countdown
    for ($i = $Seconds; $i -gt 0; $i--) {
        try { [Console]::CursorLeft = 0 } catch { }
        $remainingText = "$i seconds remaining"
        Write-Host "`r$displayMessage $progressBar" -NoNewline -ForegroundColor DarkCyan
        Write-Host " $remainingText".PadRight(25) -NoNewline -ForegroundColor Yellow
        Start-Sleep 1
    }
    
    # Show completion
    try { [Console]::CursorLeft = 0 } catch { }
    $elapsedText = if ($ResourceName) { "$ResourceName ($totalSeconds`s)" } else { "Complete ($totalSeconds`s)" }
    Write-Host "`r$displayMessage $progressBar" -NoNewline -ForegroundColor DarkCyan
    Write-Host " $elapsedText" -NoNewline -ForegroundColor Green
    Write-Host ""
}

function Write-DeploymentSummary {
    param(
        $ResourceGroup, $Region, $SqlServer, $SqlDatabase, $Container, $ContainerUrl, $ConfigPath,
        $LogAnalytics, $Environment, $CurrentUser, $DatabaseType, $TotalTime, $ClientIp, $StorageAccount, $FileShare, $SqlServerFqdn, $FirewallRuleName
    )
    
    $subscriptionIdResult = Invoke-AzCli -Arguments @('account', 'show', '--query', 'id', '--output', 'tsv')
    Assert-Success -ExitCode $subscriptionIdResult.ExitCode -Message "Failed to retrieve subscription id for summary" -CommandOutput $subscriptionIdResult.Text
    $subscriptionId = $subscriptionIdResult.TrimmedText
    
    Write-Host "`n" -NoNewline
    Write-Host "=============================================================================="
    Write-Host "  DAB DEMO DEPLOYMENT SUMMARY" -ForegroundColor Green
    Write-Host "=============================================================================="
    
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
    if ($ConfigPath) {
        Write-Host "    Config Path:     $ConfigPath"
    }
    Write-Host ""
    Write-Host "  Storage Account:   $StorageAccount"
    Write-Host "    File Share:      $FileShare"
    Write-Host "    Purpose:         Hosts dab-config.json (mounted at /mnt/dab-config)"
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
    
    Write-Host "=============================================================================="
}

function Assert-ResourceNameLength {
    <#
    .SYNOPSIS
    Validates and trims Azure resource names to their service-specific length limits.
    
    .DESCRIPTION
    Azure services have varying name length restrictions. This function ensures
    all resource names comply before creation to prevent cryptic deployment failures.
    
    .PARAMETER Name
    The resource name to validate/trim
    
    .PARAMETER ResourceType
    The type of Azure resource (determines max length and allowed characters)
    
    .PARAMETER MaxLength
    Override the default max length for custom scenarios
    
    .OUTPUTS
    Returns the validated (and possibly trimmed) resource name
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        
        [Parameter(Mandatory)]
        [ValidateSet(
            'ResourceGroup',        # 1-90 chars, alphanumerics, underscores, parentheses, hyphens, periods (except end)
            'StorageAccount',       # 3-24 chars, lowercase alphanumerics only
            'SqlServer',            # 1-63 chars, lowercase alphanumerics and hyphens (not start/end with hyphen)
            'Database',             # 1-128 chars, cannot use: <>*%&:\/? or control characters
            'ContainerApp',         # 1-32 chars, lowercase alphanumerics and hyphens
            'ContainerEnvironment', # 1-60 chars, alphanumerics and hyphens
            'LogAnalytics',         # 4-63 chars, alphanumerics and hyphens
            'FileShare'            # 3-63 chars, lowercase alphanumerics and hyphens
        )]
        [string]$ResourceType,
        
        [int]$MaxLength = 0
    )
    
    # Define limits per resource type (based on Azure documentation)
    $limits = @{
        'ResourceGroup'        = 90
        'StorageAccount'       = 24
        'SqlServer'            = 63
        'Database'             = 128
        'ContainerApp'         = 32
        'ContainerEnvironment' = 60
        'LogAnalytics'         = 63
        'FileShare'            = 63
    }
    
    $maxLen = if ($MaxLength -gt 0) { $MaxLength } else { $limits[$ResourceType] }
    
    if ($Name.Length -gt $maxLen) {
        $trimmedName = $Name.Substring(0, $maxLen)
        Write-Host "  Warning: $ResourceType name trimmed from $($Name.Length) to $maxLen chars" -ForegroundColor Yellow
        Write-Host "    Original: $Name" -ForegroundColor DarkGray
        Write-Host "    Trimmed:  $trimmedName" -ForegroundColor DarkGray
        return $trimmedName
    }
    
    return $Name
}

# Preflight: capture subscription context
$accountInfoResult = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json')
Assert-Success -ExitCode $accountInfoResult.ExitCode -Message "Failed to retrieve account information after login" -CommandOutput $accountInfoResult.Text

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

# Show current subscription with option to change
Write-Host "`nCurrent subscription:" -ForegroundColor Cyan
Write-Host "  Name: $currentSub" -ForegroundColor White
Write-Host "  ID:   $currentSubId" -ForegroundColor DarkGray

$confirm = Read-Host "`nDeploy to this subscription? (y/n/list) [y]"
if ($confirm) { $confirm = $confirm.Trim().ToLowerInvariant() }

if ($confirm -eq 'list' -or $confirm -eq 'l') {
    Write-Host "`nAvailable subscriptions:" -ForegroundColor Cyan
    $subscriptionListResult = Invoke-AzCli -Arguments @('account', 'list', '--query', '[].{name:name, id:id, isDefault:isDefault}', '--output', 'json')
    Assert-Success -ExitCode $subscriptionListResult.ExitCode -Message "Failed to list subscriptions" -CommandOutput $subscriptionListResult.Text
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
        Assert-Success -ExitCode $setSubscriptionResult.ExitCode -Message "Failed to switch subscription" -CommandOutput $setSubscriptionResult.Text
        # Refresh subscription info
        $accountInfoResult = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json')
        Assert-Success -ExitCode $accountInfoResult.ExitCode -Message "Failed to refresh subscription context" -CommandOutput $accountInfoResult.Text
        $accountInfo = $accountInfoResult.TrimmedText | ConvertFrom-Json
        $currentSub = $accountInfo.name
        $currentSubId = $accountInfo.id
        Write-Host "Now using: $currentSub" -ForegroundColor Green
    }
} elseif ($confirm -and $confirm -ne 'y') {
    Write-Host "Deployment cancelled by user" -ForegroundColor Yellow
    exit 0
}

# Main deployment logic wrapped in try/catch for reliable error handling
try {
    # Define resource names with timestamp
    $rg = "dab-demo-$runTimestamp"
    $acaEnv = "aca-environment-$runTimestamp"
    $container = "data-api-container"
    $sqlServer = "sql-server-$runTimestamp"
    $sqlDb = "sql-database"
    $logAnalytics = "law-environment-$runTimestamp"
    $configMountPath = "/mnt/dab-config"
    $storageShareName = "config-$runTimestamp"
    
    # Validate and trim all resource names to Azure limits
    Write-Host "`nValidating resource names..." -ForegroundColor Cyan
    $rg = Assert-ResourceNameLength -Name $rg -ResourceType 'ResourceGroup'
    $acaEnv = Assert-ResourceNameLength -Name $acaEnv -ResourceType 'ContainerEnvironment'
    $container = Assert-ResourceNameLength -Name $container -ResourceType 'ContainerApp'
    $sqlServer = Assert-ResourceNameLength -Name $sqlServer -ResourceType 'SqlServer'
    $sqlDb = Assert-ResourceNameLength -Name $sqlDb -ResourceType 'Database'
    $logAnalytics = Assert-ResourceNameLength -Name $logAnalytics -ResourceType 'LogAnalytics'
    $storageShareName = Assert-ResourceNameLength -Name $storageShareName -ResourceType 'FileShare'
    Write-Host "  All resource names validated" -ForegroundColor Green

    # Initialize Docker-style live progress UI
    $deploymentSteps = @(
        "Creating resource group",
        "Getting current Azure AD user",
        "Creating Log Analytics workspace",
        "Creating Container Apps environment",
        "Creating SQL Server",
        "Creating SQL database",
        "Configuring SQL firewall rules",
        "Testing database connectivity",
        "Deploying database",
        "Creating storage account",
        "Creating file share",
        "Creating Container App with managed identity",
        "Granting database access to managed identity",
        "Restarting container",
        "Verifying container running",
        "Fetching Container App URL"
    )
    Initialize-ProgressUI -Steps $deploymentSteps

    Set-CurrentOperation "resource-group" "Creating resource group"
    Update-ProgressUI -Step "Creating resource group" -Status "Starting"
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
    Update-ProgressUI -Step "Creating resource group" -Status "Success" -Extra $rg -ElapsedTime $rgElapsed
    Clear-CurrentOperation

    # Current AAD user
    Set-CurrentOperation "aad-user" "Getting current Azure AD user"
    Write-Progress-Step "Getting current Azure AD user" "Starting"
    $userInfoResult = Invoke-AzCli -Arguments @('ad', 'signed-in-user', 'show', '--query', '{id:id,upn:userPrincipalName}', '--output', 'json')
    Assert-Success -ExitCode $userInfoResult.ExitCode -Message "Failed to identify Azure AD user" -CommandOutput $userInfoResult.Text
    $userInfo = $userInfoResult.TrimmedText | ConvertFrom-Json
    $currentUser = $userInfo.id
    $currentUserName = $userInfo.upn
    Update-ProgressUI -Step "Getting current Azure AD user" -Status "Success" -Extra $currentUserName
    Clear-CurrentOperation

    # Log Analytics
    Set-CurrentOperation "log-analytics" "Creating Log Analytics workspace"
    Write-Progress-Step "Creating Log Analytics workspace" "Starting"
    $lawStartTime = Get-Date
    Start-Heartbeat -Message "Creating Log Analytics workspace"
    $lawCreateArgs = @('monitor', 'log-analytics', 'workspace', 'create', '--resource-group', $rg, '--workspace-name', $logAnalytics, '--location', $Region, '--tags') + $commonTagValues
    $lawCreateResult = Invoke-AzCli -Arguments $lawCreateArgs
    Stop-Heartbeat
    Assert-Success -ExitCode $lawCreateResult.ExitCode -Message "Failed to create Log Analytics workspace" -CommandOutput $lawCreateResult.Text
    
    # Get the customerId (GUID) - required for Container Apps environment
    $lawCustomerIdArgs = @('monitor', 'log-analytics', 'workspace', 'show', '--resource-group', $rg, '--workspace-name', $logAnalytics, '--query', 'customerId', '--output', 'tsv')
    $lawCustomerIdResult = Invoke-AzCli -Arguments $lawCustomerIdArgs
    Assert-Success -ExitCode $lawCustomerIdResult.ExitCode -Message "Failed to get Log Analytics customerId" -CommandOutput $lawCustomerIdResult.Text
    $lawCustomerId = $lawCustomerIdResult.TrimmedText.Trim()
    
    # Validate customerId is a proper GUID
    if ($lawCustomerId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw "Log Analytics customerId is not a valid 36-character GUID. Got: '$lawCustomerId'"
    }
    
    # Get the shared key for Container Apps environment
    $lawKeyArgs = @('monitor', 'log-analytics', 'workspace', 'get-shared-keys', '--resource-group', $rg, '--workspace-name', $logAnalytics, '--query', 'primarySharedKey', '--output', 'tsv')
    $lawKeyResult = Invoke-AzCli -Arguments $lawKeyArgs
    Assert-Success -ExitCode $lawKeyResult.ExitCode -Message "Failed to get Log Analytics workspace key" -CommandOutput $lawKeyResult.Text
    $lawPrimaryKey = $lawKeyResult.TrimmedText.Trim()
    
    # Validate key is not empty
    if ([string]::IsNullOrWhiteSpace($lawPrimaryKey)) {
        throw "Log Analytics primarySharedKey came back empty"
    }
    
    $lawElapsed = [math]::Round(((Get-Date) - $lawStartTime).TotalSeconds, 1)
    Update-ProgressUI -Step "Creating Log Analytics workspace" -Status "Success" -Extra $logAnalytics -ElapsedTime $lawElapsed
    Clear-CurrentOperation

    $lawUpdateArgs = @('monitor', 'log-analytics', 'workspace', 'update', '--resource-group', $rg, '--workspace-name', $logAnalytics, '--tags') + $commonTagValues + @('--retention-time', $Config.LogRetentionDays.ToString())
    $lawUpdateResult = Invoke-AzCli -Arguments $lawUpdateArgs
    Assert-Success -ExitCode $lawUpdateResult.ExitCode -Message "Failed to update Log Analytics retention" -CommandOutput $lawUpdateResult.Text

    # ACA environment
    Set-CurrentOperation "container-apps-env" "Creating Container Apps environment"
    Update-ProgressUI -Step "Creating Container Apps environment" -Status "Starting"
    
    # Check token before long operation (silence return value)
    [void](Test-AzureTokenExpiry -ExpiryBufferMinutes 5)
    
    $acaStartTime = Get-Date
    Start-Heartbeat -Message "Creating Container Apps environment (this may take 2-3 minutes)"
    $acaArgs = @('containerapp', 'env', 'create', '--name', $acaEnv, '--resource-group', $rg, '--location', $Region, '--logs-workspace-id', $lawCustomerId, '--logs-workspace-key', $lawPrimaryKey, '--tags') + $commonTagValues
    $acaCreateResult = Invoke-AzCli -Arguments $acaArgs
    Stop-Heartbeat
    Assert-Success -ExitCode $acaCreateResult.ExitCode -Message "Failed to create Container Apps environment" -CommandOutput $acaCreateResult.Text
    $acaElapsed = [math]::Round(((Get-Date) - $acaStartTime).TotalSeconds, 1)
    Update-ProgressUI -Step "Creating Container Apps environment" -Status "Success" -Extra $acaEnv -ElapsedTime $acaElapsed
    Clear-CurrentOperation

    # SQL Server (AAD-only) - Set admin at creation time for reliability
    Set-CurrentOperation "sql-server" "Creating SQL Server"
    Update-ProgressUI -Step "Creating SQL Server" -Status "Starting"
    
    Start-Heartbeat -Message "Creating SQL Server with Entra ID authentication"
    # Check token before SQL operations (can be slow in some regions)
    [void](Test-AzureTokenExpiry -ExpiryBufferMinutes 5)
    
    $sqlStartTime = Get-Date
    $sqlServerArgs = @(
        'sql', 'server', 'create',
        '--name', $sqlServer,
        '--resource-group', $rg,
        '--location', $Region,
        '--enable-ad-only-auth',
        '--external-admin-principal-type', 'User',
        '--external-admin-name', $currentUserName,
        '--external-admin-sid', $currentUser,
        '--tags'
    ) + $commonTagValues
    $sqlServerResult = Invoke-AzCli -Arguments $sqlServerArgs
    Stop-Heartbeat
    Assert-Success -ExitCode $sqlServerResult.ExitCode -Message "Failed to create SQL server" -CommandOutput $sqlServerResult.Text
    $sqlElapsed = [math]::Round(((Get-Date) - $sqlStartTime).TotalSeconds, 1)
    Update-ProgressUI -Step "Creating SQL Server" -Status "Success" -Extra $sqlServer -ElapsedTime $sqlElapsed
    
    # Get actual FQDN from server properties (more reliable than constructing)
    Write-Progress-Step "Retrieving SQL Server FQDN" "Starting"
    $sqlFqdnArgs = @('sql', 'server', 'show', '--name', $sqlServer, '--resource-group', $rg, '--query', 'fullyQualifiedDomainName', '--output', 'tsv')
    $sqlFqdnResult = Invoke-AzCli -Arguments $sqlFqdnArgs
    Assert-Success -ExitCode $sqlFqdnResult.ExitCode -Message "Failed to retrieve SQL Server FQDN" -CommandOutput $sqlFqdnResult.Text
    $sqlServerFqdn = $sqlFqdnResult.TrimmedText
    Write-Progress-Step "SQL Server FQDN retrieved" "Success" $sqlServerFqdn

    # Add firewall rule for current machine with retry logic
    Write-Progress-Step "Adding firewall rule for local machine access" "Starting"
    $clientIp = $null
    $ipServices = @("https://api.ipify.org", "https://ifconfig.me", "https://icanhazip.com")
    
    foreach ($service in $ipServices) {
        try {
            $clientIp = Invoke-RestMethod -Uri $service -TimeoutSec 5 -ErrorAction Stop
            $clientIp = $clientIp?.Trim()
            if ($clientIp -and $clientIp -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                break
            }
        } catch {
            Write-Progress-Step "IP detection service $service failed, trying next..." "Warning"
            continue
        }
    }
    
    if (-not $clientIp) { throw "Unable to detect public IP address from any service. Check network connectivity." }
    $firewallRuleName = "AllowLocalMachine-$runTimestamp"
    $firewallArgs = @('sql', 'server', 'firewall-rule', 'create', '--resource-group', $rg, '--server', $sqlServer, '--name', $firewallRuleName, '--start-ip-address', $clientIp, '--end-ip-address', $clientIp)
    $firewallResult = Invoke-AzCli -Arguments $firewallArgs
    Assert-Success -ExitCode $firewallResult.ExitCode -Message "Failed to create firewall rule" -CommandOutput $firewallResult.Text
    Write-Progress-Step "Firewall rule created for IP: $clientIp" "Success"
    
    # Quick connectivity sanity check (TCP 1433 reachability)
    Write-Progress-Step "Testing SQL Server connectivity on port 1433" "Starting"
    try {
        $connTest = Test-NetConnection -ComputerName $sqlServerFqdn -Port 1433 -WarningAction SilentlyContinue -InformationLevel Quiet
        if ($connTest.TcpTestSucceeded) {
            Write-Progress-Step "SQL Server port 1433 reachable" "Success"
        } else {
            Write-Progress-Step "Port 1433 not reachable (corporate firewall may block)" "Warning"
            Write-Host "  Continuing anyway - sqlcmd will fail later if blocked" -ForegroundColor Yellow
        }
    } catch {
        Write-Progress-Step "Connectivity test skipped (Test-NetConnection unavailable)" "Warning"
    }

    # Wait for SQL Server to be fully ready (Entra integration needs time)
    Start-CountdownSleep $Config.PropagationWaitSec "Waiting for SQL Server Entra ID integration" "Propagation delay"
    
    # Poll AAD-only auth state to confirm propagation (defensive against multi-region delays)
    Write-Progress-Step "Verifying Entra ID authentication is active" "Starting"
    $adOnlyReady = $false
    $adOnlyWaitStart = Get-Date
    $maxAdOnlyWaitSeconds = 60
    
    while (-not $adOnlyReady -and ((Get-Date) - $adOnlyWaitStart).TotalSeconds -lt $maxAdOnlyWaitSeconds) {
        $adOnlyStateArgs = @('sql', 'server', 'ad-only-auth', 'get', '--resource-group', $rg, '--server-name', $sqlServer, '--query', 'azureAdOnlyAuthentication', '--output', 'tsv')
        $adOnlyStateResult = Invoke-AzCli -Arguments $adOnlyStateArgs
        
        if ($adOnlyStateResult.ExitCode -eq 0 -and $adOnlyStateResult.TrimmedText -eq 'true') {
            $adOnlyReady = $true
        } else {
            Start-Sleep -Seconds 5
        }
    }
    
    if (-not $adOnlyReady) {
        Write-Progress-Step "Entra ID auth state not confirmed, proceeding anyway" "Warning"
    } else {
        Write-Progress-Step "Entra ID authentication verified active" "Success"
    }

    # Check free database capacity first (documented pattern: az sql db list-usages)
    Write-Progress-Step "Checking free database capacity" "Starting"
    $freeCapArgs = @('sql', 'db', 'list-usages', '--resource-group', $rg, '--server', $sqlServer, '--query', "[?name.value=='FreeDatabaseCount']", '--output', 'json')
    $freeCapResult = Invoke-AzCli -Arguments $freeCapArgs
    
    $canUseFree = $false
    if ($freeCapResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($freeCapResult.TrimmedText)) {
        $freeCapJson = $freeCapResult.TrimmedText | ConvertFrom-Json
        if ($freeCapJson -and $freeCapJson.Count -gt 0) {
            $currentVal = [int]$freeCapJson[0].currentValue
            $limitVal = [int]$freeCapJson[0].limit
            if ($currentVal -lt $limitVal) {
                $canUseFree = $true
                Write-Progress-Step "Free database capacity available ($currentVal/$limitVal used)" "Success"
            } else {
                Write-Progress-Step "Free database capacity exhausted ($currentVal/$limitVal used)" "Warning"
            }
        }
    }
    
    if (-not $canUseFree) {
        # Free tier unavailable or capacity check failed
        Write-Host "`nFree-tier database not available (may be region/subscription limited)" -ForegroundColor Yellow
    }

    # Try creating free-tier DB if capacity available, fallback to smallest paid
    if ($canUseFree) {
        Write-Progress-Step "Creating free-tier SQL Database" "Starting"
    } else {
        Write-Progress-Step "Creating paid-tier SQL Database (free unavailable)" "Starting"
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
            $freeMessage = if ($freeDbOutput) { $freeDbOutput } else { 'Creation failed despite capacity check' }
            Write-Host "`nFree-tier database creation failed: $freeMessage" -ForegroundColor Yellow
        }
    }
    
    if (-not $dbCreated) {
        Write-Host "`nFalling back to Serverless database (PAID TIER)" -ForegroundColor Yellow
        Write-Host "  Auto-pause enabled: 60 minutes of inactivity" -ForegroundColor Cyan
        Write-Host "  Estimated cost when paused: ~`$5/month" -ForegroundColor Yellow
        Write-Host "  Estimated cost if active 24/7: ~`$150/month" -ForegroundColor Red
        
        $proceed = Read-Host "`nContinue with paid database tier? (y/n) [n]"
        if ($proceed -ne 'y') {
            throw "Deployment cancelled - paid database tier not accepted by user"
        }
        
        $fallbackDbArgs = @(
            'sql', 'db', 'create',
            '--name', $sqlDb,
            '--server', $sqlServer,
            '--resource-group', $rg,
            '--tags') +
            $commonTagValues +
            @('--compute-model', 'Serverless', '--tier', 'GeneralPurpose', '--min-capacity', '0.5', '--auto-pause-delay', '60', '--backup-storage-redundancy', 'Local')
        $fallbackDbResult = Invoke-AzCli -Arguments $fallbackDbArgs
        Assert-Success -ExitCode $fallbackDbResult.ExitCode -Message "Failed to create fallback SQL database" -CommandOutput $fallbackDbResult.Text
        $dbType = "Serverless (paid)"
    }
    
    $dbElapsed = [math]::Round(((Get-Date) - $dbStartTime).TotalSeconds, 1)
    Update-ProgressUI -Step "Creating SQL database" -Status "Success" -Extra "$sqlDb ($dbType)" -ElapsedTime $dbElapsed

    # Storage Account + File Share for dab-config.json
    # Use hash-based naming to avoid collisions from timestamp reuse
    $rgHash = [BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($rg))).Replace("-", "").Substring(0, 8).ToLowerInvariant()
    $storageAccount = "stg$rgHash$runTimestamp" -replace '-', ''
    $storageAccount = $storageAccount.ToLowerInvariant()
    # Validate storage account name (3-24 chars, lowercase alphanumerics only)
    $storageAccount = Assert-ResourceNameLength -Name $storageAccount -ResourceType 'StorageAccount'
    
    Update-ProgressUI -Step "Creating storage account" -Status "Starting"
    $storageStartTime = Get-Date
    $storageArgs = @('storage', 'account', 'create', '--name', $storageAccount, '--resource-group', $rg, '--location', $Region, '--sku', 'Standard_LRS', '--kind', 'StorageV2', '--tags') + $commonTagValues
    $storageResult = Invoke-AzCli -Arguments $storageArgs
    Assert-Success -ExitCode $storageResult.ExitCode -Message "Failed to create storage account" -CommandOutput $storageResult.Text
    $storageElapsed = [math]::Round(((Get-Date) - $storageStartTime).TotalSeconds, 1)
    
    # Get storage account key
    Write-Progress-Step "  Retrieving storage account key" "Info"
    $storageKeyArgs = @('storage', 'account', 'keys', 'list', '--account-name', $storageAccount, '--resource-group', $rg, '--query', '[0].value', '--output', 'tsv')
    $storageKeyResult = Invoke-AzCli -Arguments $storageKeyArgs
    Assert-Success -ExitCode $storageKeyResult.ExitCode -Message "Failed to retrieve storage key" -CommandOutput $storageKeyResult.Text
    $storageKey = $storageKeyResult.TrimmedText
    Update-ProgressUI -Step "Creating storage account" -Status "Success" -Extra $storageAccount -ElapsedTime $storageElapsed
    
    # SECURITY: Storage key will be redacted from transcript at end of deployment
    
    # NOTE: For production, consider:
    # 1. Rotating storage keys periodically: az storage account keys renew --account-name $storageAccount --key primary
    # 2. Using managed identity-based mounts when GA for Container Apps (currently in preview)
    # 3. Storing keys in Azure Key Vault instead of script memory
    # 4. User-assigned MI with "Storage File Data SMB Share Contributor" role (preview, more secure than key-based auth)
    
    # Create file share with unique name per deployment
    Write-Progress-Step "Creating Azure File Share" "Starting"
    $fileShareArgs = @('storage', 'share', 'create', '--name', $storageShareName, '--account-name', $storageAccount, '--account-key', $storageKey, '--quota', $Config.StorageShareQuotaGb.ToString())
    $fileShareResult = Invoke-AzCli -Arguments $fileShareArgs
    Assert-Success -ExitCode $fileShareResult.ExitCode -Message "Failed to create file share" -CommandOutput $fileShareResult.Text
    Write-Progress-Step "Azure File Share created" "Success" $storageShareName
    
    # Upload dab-config.json to file share (with path quoting for safety)
    if (Test-Path $ConfigPath) {
        Write-Progress-Step "Uploading dab-config.json to file share" "Starting"
        $configFilePath = (Resolve-Path $ConfigPath).Path
        
        # Retry upload to handle transient 429s or propagation delays
        $uploadSuccess = $false
        $uploadRetries = 0
        $maxUploadRetries = 3
        
        while (-not $uploadSuccess -and $uploadRetries -lt $maxUploadRetries) {
            $uploadRetries++
            
            # Quote the source path to handle spaces safely
            $uploadArgs = @('storage', 'file', 'upload', '--account-name', $storageAccount, '--account-key', $storageKey, '--share-name', $storageShareName, '--source', "`"$configFilePath`"", '--path', 'dab-config.json')
            $uploadResult = Invoke-AzCli -Arguments $uploadArgs
            
            if ($uploadResult.ExitCode -eq 0) {
                $uploadSuccess = $true
            } elseif ($uploadRetries -lt $maxUploadRetries) {
                $waitSeconds = 5 * $uploadRetries
                Write-Progress-Step "Upload transient failure, retrying in $waitSeconds seconds (attempt $uploadRetries/$maxUploadRetries)" "Warning"
                Start-Sleep $waitSeconds
            }
        }
        
        if (-not $uploadSuccess) {
            Assert-Success -ExitCode $uploadResult.ExitCode -Message "Failed to upload dab-config.json after $maxUploadRetries attempts" -CommandOutput $uploadResult.Text
        }
        
        Write-Progress-Step "dab-config.json uploaded to file share" "Success"
    } else {
        throw "dab-config.json file validation failed at path: $ConfigPath"
    }
    $configPath = "$configMountPath/dab-config.json"

    # Add storage to Container Apps environment
    # NOTE: Using ReadOnly mode - if DAB needs write access for logs/cache, change to ReadWrite
    Write-Progress-Step "Adding storage to Container Apps environment" "Starting"
    
    # Idempotent: delete existing env storage if present (prevents "already exists" on re-runs)
    $envStorageDeleteArgs = @('containerapp', 'env', 'storage', 'delete', '--name', $acaEnv, '--resource-group', $rg, '--storage-name', 'dab-config-storage', '--yes')
    $null = Invoke-AzCli -Arguments $envStorageDeleteArgs
    # Ignore errors (storage may not exist on first run)
    
    $envStorageArgs = @(
        'containerapp', 'env', 'storage', 'set',
        '--name', $acaEnv,
        '--resource-group', $rg,
        '--storage-name', 'dab-config-storage',
        '--azure-file-account-name', $storageAccount,
        '--azure-file-account-key', $storageKey,
        '--azure-file-share-name', $storageShareName,
        '--access-mode', 'ReadOnly'
    )
    $envStorageResult = Invoke-AzCli -Arguments $envStorageArgs
    Assert-Success -ExitCode $envStorageResult.ExitCode -Message "Failed to add storage to environment" -CommandOutput $envStorageResult.Text
    Write-Progress-Step "Storage added to environment" "Success"
    
    # Clear storage key from memory for security hygiene
    Remove-Variable -Name storageKey -ErrorAction SilentlyContinue
    [System.GC]::Collect()  # Force garbage collection to scrub sensitive data from memory
    
    # Verify storage mount is ready with polling (max 30 seconds)
    Write-Progress-Step "Verifying storage mount readiness" "Starting"
    $storageReady = $false
    $maxWaitSeconds = 30
    $waitStart = Get-Date
    
    while (-not $storageReady -and ((Get-Date) - $waitStart).TotalSeconds -lt $maxWaitSeconds) {
        $storageCheckArgs = @('containerapp', 'env', 'storage', 'show', '--name', $acaEnv, '--resource-group', $rg, '--storage-name', 'dab-config-storage', '--query', 'properties.azureFile.shareName', '--output', 'tsv')
        $storageCheckResult = Invoke-AzCli -Arguments $storageCheckArgs
        
        if ($storageCheckResult.ExitCode -eq 0 -and $storageCheckResult.TrimmedText -eq $storageShareName) {
            $storageReady = $true
        } else {
            Start-Sleep -Seconds 2
        }
    }
    
    if (-not $storageReady) {
        throw "Storage mount did not become ready within $maxWaitSeconds seconds"
    }
    Write-Progress-Step "Storage mount verified and ready" "Success"

    # Container + Identity
    Write-Progress-Step "Creating Container App with Data API Builder" "Starting"
    
    # Check token before container creation
    [void](Test-AzureTokenExpiry -ExpiryBufferMinutes 5)
    
    $containerStartTime = Get-Date
    Start-Heartbeat -Message "Creating Container App with DAB image"
    
    # Use modern --mounts JSON array syntax (preferred over deprecated --bind-mount)
    $mountsJson = '[{"volumeName":"dab-config-storage","mountPath":"' + $configMountPath + '"}]'
    
    $containerArgs = @(
        'containerapp', 'create',
        '--name', $container,
        '--resource-group', $rg,
        '--environment', $acaEnv,
        '--image', $ContainerImage,
        '--cpu', $Config.ContainerCpu,
        '--memory', $Config.ContainerMemory,
        '--assign-identity', 'system',
        '--ingress', 'external', '--target-port', '5000',
        '--tags'
    ) + $commonTagValues + @('--mounts', $mountsJson)
    
    $containerCreateResult = Invoke-AzCli -Arguments $containerArgs
    Stop-Heartbeat
    Assert-Success -ExitCode $containerCreateResult.ExitCode -Message "Failed to create container app" -CommandOutput $containerCreateResult.Text
    $containerElapsed = [math]::Round(((Get-Date) - $containerStartTime).TotalSeconds, 1)
    Write-Progress-Step "Container App created with managed identity" "Success" $container $containerElapsed

    # Get managed identity principal ID immediately
    Write-Progress-Step "Retrieving managed identity principal ID" "Starting"
    $principalIdArgs = @('containerapp', 'show', '--name', $container, '--resource-group', $rg, '--query', 'identity.principalId', '--output', 'tsv')
    $principalIdResult = Invoke-AzCli -Arguments $principalIdArgs
    Assert-Success -ExitCode $principalIdResult.ExitCode -Message "Failed to retrieve MI principal ID" -CommandOutput $principalIdResult.Text
    $principalId = $principalIdResult.TrimmedText
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        throw "Managed identity principal ID is empty or null"
    }
    Write-Progress-Step "Managed identity principal ID retrieved" "Success" $principalId.Substring(0, 8)

    # Query Entra ID for the actual service principal display name
    Write-Progress-Step "Querying Entra ID for MI service principal name" "Starting"
    $spDisplayNameArgs = @('ad', 'sp', 'show', '--id', $principalId, '--query', 'displayName', '--output', 'tsv')
    $spDisplayNameResult = Invoke-AzCli -Arguments $spDisplayNameArgs
    Assert-Success -ExitCode $spDisplayNameResult.ExitCode -Message "Failed to query service principal display name" -CommandOutput $spDisplayNameResult.Text
    $spDisplayName = $spDisplayNameResult.TrimmedText
    if ([string]::IsNullOrWhiteSpace($spDisplayName)) {
        throw "Service principal display name is empty - MI may not be fully propagated"
    }
    Write-Progress-Step "Service principal display name retrieved" "Success" $spDisplayName

    # SQL access for container identity with exponential backoff retry
    Write-Progress-Step "Granting managed identity access to SQL Database" "Starting"
    
    # CRITICAL: Use the actual Entra ID display name that SQL Server will recognize
    # When using "CREATE USER [name] FROM EXTERNAL PROVIDER", SQL looks up [name] in Entra ID
    $sqlUserName = $spDisplayName
    
    $retries = 0
    $maxRetries = 5
    $success = $false
    
    while (-not $success -and $retries -lt $maxRetries) {
        $retries++
        try {
            # Escape single quotes in display name for SQL safety
            $escapedUserName = $sqlUserName.Replace("'", "''")
            $sqlQuery = "IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '$escapedUserName') BEGIN CREATE USER [$sqlUserName] FROM EXTERNAL PROVIDER; END; ALTER ROLE db_datareader ADD MEMBER [$sqlUserName]; ALTER ROLE db_datawriter ADD MEMBER [$sqlUserName];"
            sqlcmd -S $sqlServerFqdn -d $sqlDb -G -Q $sqlQuery 2>&1 | Out-Null
            $sqlExit = $LASTEXITCODE
            $success = $sqlExit -eq 0
        } catch {
            Write-Progress-Step "SQL error: $($_.Exception.Message)" "Warning"
            $success = $false
        }
        
        if (-not $success -and $retries -lt $maxRetries) {
            # Exponential backoff with jitter: 15s, 30s, 60s, 120s + random 1-5s offset
            $baseWaitSeconds = [Math]::Min(120, 15 * [Math]::Pow(2, $retries - 1))
            $jitter = Get-Random -Minimum 1 -Maximum 5
            $waitSeconds = $baseWaitSeconds + $jitter
            Write-Progress-Step "MI not ready in SQL, retrying in $waitSeconds seconds (attempt $retries/$maxRetries)" "Warning"
            Start-Sleep $waitSeconds
        }
    }
    
    if (-not $success) { 
        throw "Failed to grant SQL access after $maxRetries attempts. MI may not be propagated to SQL Server's Entra cache (exit code: $sqlExit)" 
    }
    Write-Progress-Step "SQL Database permissions granted to managed identity" "Success" $sqlUserName

    # Update container with connection string (Managed Identity)
    Write-Progress-Step "Configuring DAB connection string" "Starting"
    # Use explicit "Active Directory Managed Identity" instead of "Active Directory Default"
    # This prevents credential chain confusion if AZURE_* env vars are set
    $connectionString = "Server=tcp:${sqlServerFqdn},1433;Database=${sqlDb};Authentication=Active Directory Managed Identity;"
    $configPath = "$configMountPath/dab-config.json"
    
    # CLI expects space-separated key=value pairs (no quotes around values per docs)
    # MSSQL_CONNECTION_STRING matches the @env() reference in dab-config.json
    $envVars = @(
        "MSSQL_CONNECTION_STRING=$connectionString",
        "Runtime__ConfigFile=$configPath"
    )
    
    $updateArgs = @(
        'containerapp', 'update',
        '--name', $container,
        '--resource-group', $rg,
        '--set-env-vars'
    ) + $envVars
    $containerUpdateResult = Invoke-AzCli -Arguments $updateArgs
    Assert-Success -ExitCode $containerUpdateResult.ExitCode -Message "Failed to update container configuration" -CommandOutput $containerUpdateResult.Text
    Write-Progress-Step "DAB connection string configured" "Success"
    
    # Restart container to ensure MI is fully propagated before DAB starts
    Write-Progress-Step "Restarting container to activate configuration" "Starting"
    $restartArgs = @('containerapp', 'revision', 'restart', '--name', $container, '--resource-group', $rg)
    $restartResult = Invoke-AzCli -Arguments $restartArgs
    Assert-Success -ExitCode $restartResult.ExitCode -Message "Failed to restart container" -CommandOutput $restartResult.Text
    Write-Progress-Step "Container restarted with MI credentials" "Success"
    
    # Wait for container to actually be running (not just created)
    Write-Progress-Step "Verifying container is running" "Starting"
    $containerRunning = $false
    $maxWaitMinutes = 5
    $checkDeadline = (Get-Date).AddMinutes($maxWaitMinutes)
    $checkAttempt = 0
    
    while (-not $containerRunning -and (Get-Date) -lt $checkDeadline) {
        $checkAttempt++
        Start-Sleep -Seconds 10
        
        # Check provisioning state and running status
        $statusArgs = @('containerapp', 'show', '--name', $container, '--resource-group', $rg, '--query', '{provisioning:properties.provisioningState,running:properties.runningStatus}', '--output', 'json')
        $statusResult = Invoke-AzCli -Arguments $statusArgs
        
        if ($statusResult.ExitCode -eq 0) {
            $status = $statusResult.TrimmedText | ConvertFrom-Json
            
            if ($status.provisioning -eq 'Succeeded' -and $status.running -eq 'Running') {
                # Also check replica health to detect crash loops
                $replicaArgs = @('containerapp', 'replica', 'list', '--name', $container, '--resource-group', $rg, '--query', '[0].properties.containers[0].restartCount', '--output', 'tsv')
                $replicaResult = Invoke-AzCli -Arguments $replicaArgs
                
                if ($replicaResult.ExitCode -eq 0) {
                    $restartCount = $replicaResult.TrimmedText
                    if ([string]::IsNullOrWhiteSpace($restartCount)) { $restartCount = "0" }
                    
                    if ([int]$restartCount -lt 3) {
                        $containerRunning = $true
                        Write-Progress-Step "Container verified running (restart count: $restartCount)" "Success"
                    } else {
                        Write-Progress-Step "Container in crash loop (restart count: $restartCount)" "Warning"
                    }
                }
            } else {
                Write-Progress-Step "Container state: $($status.provisioning)/$($status.running) (attempt $checkAttempt)" "Info"
            }
        }
    }
    
    if (-not $containerRunning) {
        # Container didn't start properly - fetch logs for diagnosis
        Write-Progress-Step "Container failed to start, retrieving logs" "Warning"
        $logsArgs = @('containerapp', 'logs', 'show', '--name', $container, '--resource-group', $rg, '--tail', '50')
        $logsResult = Invoke-AzCli -Arguments $logsArgs
        $logOutput = if ($logsResult.TrimmedText) { $logsResult.TrimmedText } else { "No logs available" }
        throw "Container did not reach Running state within $maxWaitMinutes minutes. Recent logs:`n$logOutput"
    }

    # Execute database script if exists
    if (Test-Path $DatabasePath) {
        Write-Progress-Step "Executing database script from $DatabasePath" "Starting"
        sqlcmd -S $sqlServerFqdn -d $sqlDb -G -i $DatabasePath
        $sqlExit = $LASTEXITCODE
        if ($sqlExit -ne 0) { 
            Write-Progress-Step "Database execution failed (code $sqlExit), continuing..." "Warning"
        } else {
            Write-Progress-Step "Database script executed successfully" "Success"
        }
    } else {
        # This should never happen due to validation at top, but keep as failsafe
        throw "database.sql file validation failed at path: $DatabasePath"
    }

    # Get container app URL for summary  
    $containerShowArgs = @('containerapp', 'show', '--name', $container, '--resource-group', $rg, '--query', 'properties.configuration.ingress.fqdn', '--output', 'tsv')
    $containerShowResult = Invoke-AzCli -Arguments $containerShowArgs
    if ($containerShowResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($containerShowResult.TrimmedText)) {
        $containerUrl = "https://$($containerShowResult.TrimmedText)"
        
        # Health check - verify DAB API is responding
        Write-Progress-Step "Checking DAB API health endpoint" "Starting"
        try {
            $healthUrl = "$containerUrl/health"
            $healthResponse = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 10 -ErrorAction Stop
            
            if ($healthResponse.status -eq "Healthy") {
                Write-Progress-Step "DAB API health check: Healthy" "Success"
            } elseif ($healthResponse.status -eq "Unhealthy") {
                # Check individual data source health
                $dbCheck = $healthResponse.checks | Where-Object { $_.tags -contains "data-source" } | Select-Object -First 1
                if ($dbCheck -and $dbCheck.status -eq "Healthy") {
                    Write-Progress-Step "DAB API responding (database connection healthy, overall status: $($healthResponse.status))" "Warning"
                } else {
                    Write-Progress-Step "DAB API health check: $($healthResponse.status) - database may need verification" "Warning"
                }
            } else {
                Write-Progress-Step "DAB API health check returned unexpected status: $($healthResponse.status)" "Warning"
            }
        } catch {
            Write-Progress-Step "Unable to verify DAB API health (may still be starting)" "Warning"
            Write-Host "  Health endpoint: $healthUrl" -ForegroundColor DarkGray
        }
    } else {
        $containerUrl = "Not available (ingress not configured)"
        $ingressMessage = if ($containerShowResult.TrimmedText) { $containerShowResult.TrimmedText } else { "Container ingress not ready" }
        Write-Progress-Step $ingressMessage "Warning"
    }

    Write-Progress-Step "Reminder: remove SQL firewall rule when done" "Info"

    # Calculate total deployment time and display summary
    $totalTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
    $totalTimeFormatted = "${totalTime}m"

    Write-DeploymentSummary -ResourceGroup $rg -Region $Region -SqlServer $sqlServer -SqlDatabase $sqlDb `
        -Container $container -ContainerUrl $containerUrl -ConfigPath $configPath -LogAnalytics $logAnalytics `
        -Environment $acaEnv -CurrentUser $currentUserName -DatabaseType $dbType -TotalTime $totalTimeFormatted `
        -ClientIp $clientIp -StorageAccount $storageAccount -FileShare $storageShareName -SqlServerFqdn $sqlServerFqdn `
        -FirewallRuleName $firewallRuleName

    # Save deployment summary as JSON for auditability
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
            StorageAccount = $storageAccount
            FileShare = $storageShareName
            ConfigFilePath = $configPath
        }
        DeploymentTime = $totalTimeFormatted
        CurrentUser = $currentUserName
        Tags = @{
            author = 'dab-deploy-demo-script'
            version = $Version
            owner = $ownerTagValue
        }
    }
    $deploymentSummary | ConvertTo-Json -Depth 3 | Out-File "dab-deploy-$runTimestamp.json" -Encoding UTF8
    Write-Progress-Step "Deployment summary saved to current directory" "Info" "dab-deploy-$runTimestamp.json"
    
    # Stop transcript and redact sensitive data
    Stop-Transcript | Out-Null
    
    # Redact storage keys from transcript for security
    if (Test-Path $transcriptPath) {
        try {
            $transcriptContent = Get-Content $transcriptPath -Raw -ErrorAction Stop
            
            # Redact storage account keys
            if ($storageKey) {
                $transcriptContent = $transcriptContent -replace [regex]::Escape($storageKey), "***REDACTED_STORAGE_KEY***"
            }
            
            # Redact Log Analytics workspace key
            if ($lawPrimaryKey) {
                $transcriptContent = $transcriptContent -replace [regex]::Escape($lawPrimaryKey), "***REDACTED_LAW_KEY***"
            }
            
            # Redact any other base64-like keys (defensive)
            $transcriptContent = $transcriptContent -replace '([A-Za-z0-9+/]{64,}==?)', '***REDACTED_KEY***'
            
            # Write redacted content back
            $transcriptContent | Out-File $transcriptPath -Encoding UTF8 -Force
            Write-Host "Deployment transcript saved (sensitive data redacted): $transcriptPath" -ForegroundColor Green
        } catch {
            Write-Host "Warning: Unable to redact transcript, please review manually: $transcriptPath" -ForegroundColor Yellow
        }
    }

    # Only open portal in interactive shells and if not disabled
    if (-not $NoBrowser -and $Host.Name -ne 'ServerRemoteHost' -and $Host.Name -notlike '*Background*') {
        Write-Host "`nOpening Azure Portal..." -ForegroundColor Cyan
        try {
            Start-Process "https://portal.azure.com/#view/HubsExtension/BrowseResourceGroups/resourceGroup/$rg"
        } catch {
            Write-Progress-Step "Portal opening not supported in this shell" "Info"
        }
    }

} catch {
    Write-Host "`n" # New line for spacing
    Write-Host ("=" * 85) -ForegroundColor Red
    Write-Host "DEPLOYMENT FAILED" -ForegroundColor Red -BackgroundColor Black
    Write-Host ("=" * 85) -ForegroundColor Red
    
    # Show simplified error
    $simplifiedError = Get-SimplifiedError -ErrorMessage $_.Exception.Message
    Write-Host "`nError: $simplifiedError" -ForegroundColor Yellow
    
    # Stop transcript and redact sensitive data
    try { 
        Stop-Transcript | Out-Null 
        
        if (Test-Path $transcriptPath) {
            $transcriptContent = Get-Content $transcriptPath -Raw -ErrorAction SilentlyContinue
            if ($transcriptContent) {
                if ($storageKey) {
                    $transcriptContent = $transcriptContent -replace [regex]::Escape($storageKey), "***REDACTED_STORAGE_KEY***"
                }
                if ($lawPrimaryKey) {
                    $transcriptContent = $transcriptContent -replace [regex]::Escape($lawPrimaryKey), "***REDACTED_LAW_KEY***"
                }
                $transcriptContent = $transcriptContent -replace '([A-Za-z0-9+/]{64,}==?)', '***REDACTED_KEY***'
                $transcriptContent | Out-File $transcriptPath -Encoding UTF8 -Force
            }
        }
    } catch { }
    
    # Auto-open log file for debugging
    if (Test-Path $transcriptPath) {
        Write-Host "`nOpening log file for troubleshooting..." -ForegroundColor Cyan
        try {
            Start-Process notepad $transcriptPath
        } catch {
            Write-Host "Could not open log file automatically. Please review: $transcriptPath" -ForegroundColor Yellow
        }
    }
    
    # Offer to cleanup resources
    if ($rg) {
        Write-Host "`nPartial resources were created in resource group: $rg" -ForegroundColor DarkYellow
        Write-Host "Would you like to delete the resource group to cleanup? (Y/n) [Y]: " -NoNewline -ForegroundColor White
        $response = Read-Host
        
        if ($response -eq '' -or $response -match '^[Yy]') {
            Write-Host "`nDeleting resource group $rg..." -ForegroundColor Yellow
            try {
                $deleteResult = Invoke-AzCli -Arguments @('group', 'delete', '--name', $rg, '--yes', '--no-wait')
                if ($deleteResult.ExitCode -eq 0) {
                    Write-Host "Resource group deletion initiated (running in background)" -ForegroundColor Green
                } else {
                    Write-Host "Failed to delete resource group. Please delete manually:" -ForegroundColor Red
                    Write-Host "az group delete -n $rg -y" -ForegroundColor White
                }
            } catch {
                Write-Host "Failed to delete resource group. Please delete manually:" -ForegroundColor Red
                Write-Host "az group delete -n $rg -y" -ForegroundColor White
            }
        } else {
            Write-Host "`nResource group preserved. To cleanup later, run:" -ForegroundColor Yellow
            Write-Host "az group delete -n $rg -y" -ForegroundColor White
        }
    }
    
    Write-Host "`nFor all resources created by this script:" -ForegroundColor DarkYellow
    Write-Host "az group list --tag author=dab-deploy-demo-script" -ForegroundColor White
    
    # PowerShell will exit with non-zero status due to throw
    throw
} finally {
    $ErrorActionPreference = 'Continue'
    Write-Host "`nScript completed at $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan
}

# Successful completion
exit 0