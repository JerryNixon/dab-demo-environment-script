# cleanup.ps1
# 
# Deletes resource groups created by dab-deploy-demo script
# Uses the 'author=dab-demo' tag to identify them
#
# Parameters:
#   -WhatIf: Show what would be deleted without actually deleting
#   -Force: Skip confirmation prompts (deletes ALL found groups)
#
# Examples:
#   .\cleanup.ps1                    # Interactive selection mode (default)
#   .\cleanup.ps1 -WhatIf            # Dry run
#   .\cleanup.ps1 -Force             # Delete all without prompts
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
$currentUser = az account show --query user.name -o tsv
Write-Host "Current subscription: $currentSub" -ForegroundColor Green
Write-Host "Current user:         $currentUser" -ForegroundColor Green
Write-Host ""

# Find resource groups with the author tag
Write-Host "Searching for dab-demo resource groups..." -ForegroundColor Cyan
$newGroupsJson = az group list --tag author=dab-demo --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to list resource groups" -ForegroundColor Red
    Write-Host $newGroupsJson -ForegroundColor DarkRed
    exit 1
}

$resourceGroups = @()
$newGroups = if ($newGroupsJson.Trim()) { $newGroupsJson | ConvertFrom-Json } else { @() }
if ($newGroups) { $resourceGroups += $newGroups }

# Include legacy groups created before the author tag rename (dab-deploy-demo-script)
$legacyGroupsJson = az group list --tag author=dab-deploy-demo-script --output json 2>&1
if ($LASTEXITCODE -eq 0 -and $legacyGroupsJson.Trim()) {
    $legacyGroups = $legacyGroupsJson | ConvertFrom-Json
    $legacyAdded = 0
    foreach ($legacy in $legacyGroups) {
        if (-not ($resourceGroups | Where-Object { $_.name -eq $legacy.name })) {
            $resourceGroups += $legacy
            $legacyAdded++
        }
    }
    if ($legacyAdded -gt 0) {
        Write-Host "Including $legacyAdded legacy resource group(s) tagged with author=dab-deploy-demo-script" -ForegroundColor DarkGray
    }
}

if ($resourceGroups.Count -eq 0) {
    Write-Host "No resource groups found with tags 'author=dab-demo' or 'author=dab-deploy-demo-script'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Nothing to clean up!" -ForegroundColor Green
    exit 0
}

Write-Host "Found $($resourceGroups.Count) resource group(s):" -ForegroundColor Yellow
Write-Host ""

# Build display table with index
$rgTable = @()
$index = 1
foreach ($rg in $resourceGroups) {
    # Null-safe tag access using PSObject.Properties
    $created = "unknown"
    if ($rg.tags) {
        $timestampProp = $rg.tags.PSObject.Properties['timestamp']
        if ($timestampProp) {
            $ts = $timestampProp.Value
            # Format as YYYY-MM-DD HH:MM:SS
            if ($ts -match '^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$') {
                $created = "$($Matches[1])-$($Matches[2])-$($Matches[3]) $($Matches[4]):$($Matches[5]):$($Matches[6])"
            } else {
                $created = $ts
            }
        }
    }
    
    $owner = "unknown"
    if ($rg.tags) {
        $ownerProp = $rg.tags.PSObject.Properties['owner']
        if ($ownerProp) {
            $owner = $ownerProp.Value
        }
    }
    
    # Get provisioning state
    $statusProp = $rg.properties.PSObject.Properties['provisioningState']
    $status = if ($statusProp) { $statusProp.Value } else { "unknown" }
    
    $rgTable += [PSCustomObject]@{
        '#'      = $index
        Name     = $rg.name
        Location = $rg.location
        Owner    = $owner
        Status   = $status
        Created  = $created
    }
    $index++
}

$rgTable | Format-Table -AutoSize

# WhatIf mode
if ($WhatIf) {
    Write-Host "WhatIf mode: The following resource groups would be deleted:" -ForegroundColor Yellow
    $resourceGroups | ForEach-Object { 
        $owner = "unknown"
        if ($_.tags) {
            $ownerProp = $_.tags.PSObject.Properties['owner']
            if ($ownerProp) {
                $owner = $ownerProp.Value
            }
        }
        $statusProp = $_.properties.PSObject.Properties['provisioningState']
        $status = if ($statusProp) { $statusProp.Value } else { "unknown" }
        Write-Host "  - $($_.name) (owner: $owner, status: $status)" -ForegroundColor White 
    }
    Write-Host ""
    Write-Host "No changes made (WhatIf mode)" -ForegroundColor Cyan
    exit 0
}

# Selection logic
$selectedGroups = @()

if ($Force) {
    # Delete all
    $selectedGroups = $resourceGroups
    Write-Host "Force mode: All $($selectedGroups.Count) resource group(s) will be deleted" -ForegroundColor Yellow
} else {
    # Interactive selection
    Write-Host "Select resource groups to delete:" -ForegroundColor Cyan
    Write-Host "  - Enter numbers separated by commas (e.g., 1,3,5)" -ForegroundColor White
    Write-Host "  - Enter 'all' to delete all" -ForegroundColor White
    Write-Host "  - Press Enter to cancel" -ForegroundColor White
    Write-Host ""
    
    $selection = Read-Host "Selection"
    
    if ([string]::IsNullOrWhiteSpace($selection)) {
        Write-Host "Cleanup cancelled by user" -ForegroundColor Yellow
        exit 0
    }
    
    if ($selection.Trim().ToLower() -eq 'all') {
        $selectedGroups = $resourceGroups
    } else {
        # Parse comma-separated numbers
        $numbers = $selection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
        
        foreach ($num in $numbers) {
            if ($num -ge 1 -and $num -le $resourceGroups.Count) {
                $selectedGroups += $resourceGroups[$num - 1]
            } else {
                Write-Host "WARNING: Invalid selection '$num' (valid range: 1-$($resourceGroups.Count))" -ForegroundColor Yellow
            }
        }
    }
}

if ($selectedGroups.Count -eq 0) {
    Write-Host "No resource groups selected" -ForegroundColor Yellow
    exit 0
}

# Confirmation
Write-Host ""
Write-Host "Selected resource groups for deletion:" -ForegroundColor Red
foreach ($rg in $selectedGroups) {
    $owner = "unknown"
    if ($rg.tags) {
        $ownerProp = $rg.tags.PSObject.Properties['owner']
        if ($ownerProp) {
            $owner = $ownerProp.Value
        }
    }
    $statusProp = $rg.properties.PSObject.Properties['provisioningState']
    $status = if ($statusProp) { $statusProp.Value } else { "unknown" }
    Write-Host "  - $($rg.name) (owner: $owner, status: $status, location: $($rg.location))" -ForegroundColor White
}
Write-Host ""
Write-Host "WARNING: This action cannot be undone!" -ForegroundColor Red
Write-Host ""

$confirm = Read-Host "Type 'DELETE' to confirm"

if ($confirm -ne 'DELETE') {
    Write-Host "Cleanup cancelled by user" -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Deleting resource groups..." -ForegroundColor Cyan
Write-Host ""

$successCount = 0
$failCount = 0
$skippedCount = 0
$failedGroups = @()

foreach ($rg in $selectedGroups) {
    $rgName = $rg.name
    $owner = "unknown"
    if ($rg.tags) {
        $ownerProp = $rg.tags.PSObject.Properties['owner']
        if ($ownerProp) {
            $owner = $ownerProp.Value
        }
    }
    
    # Check if already deleting
    $statusProp = $rg.properties.PSObject.Properties['provisioningState']
    $status = if ($statusProp) { $statusProp.Value } else { "unknown" }
    
    if ($status -eq 'Deleting') {
        Write-Host "  Skipping: $rgName (owner: $owner) - already deleting" -ForegroundColor DarkGray
        $skippedCount++
        continue
    }
    
    Write-Host "  Deleting: $rgName (owner: $owner)..." -NoNewline -ForegroundColor Yellow
    
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
Write-Host "Resource groups selected:      $($selectedGroups.Count)" -ForegroundColor White
Write-Host "Successfully queued:           $successCount" -ForegroundColor Green
Write-Host "Skipped (already deleting):    $skippedCount" -ForegroundColor DarkGray
Write-Host "Failed:                        $failCount" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Red" })
Write-Host ""

if ($successCount -gt 0) {
    Write-Host "NOTE: Deletions are running in the background." -ForegroundColor Yellow
    Write-Host "It may take several minutes for resources to be fully deleted." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Check status: az group list --tag author=dab-demo --output table" -ForegroundColor Cyan
}

if ($failCount -gt 0) {
    Write-Host "Failed resource groups:" -ForegroundColor Red
    $failedGroups | ForEach-Object { Write-Host "  - $_" -ForegroundColor White }
    Write-Host ""
    Write-Host "Manual cleanup may be required." -ForegroundColor Yellow
}

Write-Host "================================================================================" -ForegroundColor Cyan

exit $(if ($failCount -eq 0) { 0 } else { 1 })
