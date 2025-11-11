# cleanup.ps1
# 
# Deletes all resource groups created by dab-deploy-demo script
# Uses the 'author=dab-deploy-demo-script' tag to identify them
#
# Parameters:
#   -WhatIf: Show what would be deleted without actually deleting
#   -Force: Skip confirmation prompts
#
# Examples:
#   .\cleanup.ps1                    # Interactive mode
#   .\cleanup.ps1 -WhatIf            # Dry run
#   .\cleanup.ps1 -Force             # No prompts
#
param(
    [switch]$WhatIf,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

Write-Host "DAB Deployment Cleanup Script" -ForegroundColor Cyan
Write-Host ""

# Check Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Azure CLI is not installed" -ForegroundColor Red
    Write-Host "Please install from: https://aka.ms/installazurecliwindows" -ForegroundColor White
    exit 1
}

# Login check
Write-Host "Checking Azure authentication..." -ForegroundColor Cyan
$loginCheck = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Not logged in. Authenticating..." -ForegroundColor Yellow
    az login --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Azure login failed" -ForegroundColor Red
        exit 1
    }
}

$currentSub = az account show --query name -o tsv
Write-Host "Current subscription: $currentSub" -ForegroundColor Green
Write-Host ""

# Find resource groups with the author tag
Write-Host "Searching for dab-deploy-demo resource groups..." -ForegroundColor Cyan
$rgsJson = az group list --tag author=dab-deploy-demo-script --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to list resource groups" -ForegroundColor Red
    Write-Host $rgsJson -ForegroundColor DarkRed
    exit 1
}

$resourceGroups = $rgsJson | ConvertFrom-Json

if ($resourceGroups.Count -eq 0) {
    Write-Host "No resource groups found with tag 'author=dab-deploy-demo-script'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Nothing to clean up!" -ForegroundColor Green
    exit 0
}

Write-Host "Found $($resourceGroups.Count) resource group(s):" -ForegroundColor Yellow
Write-Host ""

# Display found resource groups
$rgTable = $resourceGroups | ForEach-Object {
    $created = if ($_.tags.timestamp) { $_.tags.timestamp } else { "unknown" }
    $owner = if ($_.tags.owner) { $_.tags.owner } else { "unknown" }
    
    [PSCustomObject]@{
        Name     = $_.name
        Location = $_.location
        Created  = $created
        Owner    = $owner
    }
}

$rgTable | Format-Table -AutoSize

# WhatIf mode
if ($WhatIf) {
    Write-Host "WhatIf mode: The following resource groups would be deleted:" -ForegroundColor Yellow
    $resourceGroups | ForEach-Object { Write-Host "  - $($_.name)" -ForegroundColor White }
    Write-Host ""
    Write-Host "No changes made (WhatIf mode)" -ForegroundColor Cyan
    exit 0
}

# Confirmation
if (-not $Force) {
    Write-Host "WARNING: This will delete all resource groups listed above!" -ForegroundColor Red
    Write-Host "This action cannot be undone." -ForegroundColor Red
    Write-Host ""
    $confirm = Read-Host "Continue? (yes/no) [no]"
    
    if ($confirm -ne 'yes') {
        Write-Host "Cleanup cancelled by user" -ForegroundColor Yellow
        exit 0
    }
}

Write-Host ""
Write-Host "Deleting resource groups..." -ForegroundColor Cyan
Write-Host ""

$successCount = 0
$failCount = 0
$failedGroups = @()

foreach ($rg in $resourceGroups) {
    $rgName = $rg.name
    Write-Host "  Deleting: $rgName..." -NoNewline -ForegroundColor Yellow
    
    $deleteResult = az group delete --name $rgName --yes --no-wait 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host " queued" -ForegroundColor Green
        $successCount++
    } else {
        Write-Host " FAILED" -ForegroundColor Red
        $failCount++
        $failedGroups += $rgName
        Write-Host "    Error: $deleteResult" -ForegroundColor DarkRed
    }
}

Write-Host ""
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "  CLEANUP SUMMARY" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Total resource groups found:  $($resourceGroups.Count)" -ForegroundColor White
Write-Host "Successfully queued:           $successCount" -ForegroundColor Green
Write-Host "Failed:                        $failCount" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Red" })
Write-Host ""

if ($successCount -gt 0) {
    Write-Host "NOTE: Deletions are running in the background." -ForegroundColor Yellow
    Write-Host "It may take several minutes for resources to be fully deleted." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Check status: az group list --tag author=dab-deploy-demo-script --output table" -ForegroundColor Cyan
}

if ($failCount -gt 0) {
    Write-Host "Failed resource groups:" -ForegroundColor Red
    $failedGroups | ForEach-Object { Write-Host "  - $_" -ForegroundColor White }
    Write-Host ""
    Write-Host "Manual cleanup may be required." -ForegroundColor Yellow
}

Write-Host "================================================================================" -ForegroundColor Cyan

exit $(if ($failCount -eq 0) { 0 } else { 1 })
