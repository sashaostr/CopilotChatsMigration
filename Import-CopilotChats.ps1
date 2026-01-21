#Requires -Version 7.5
<#
.SYNOPSIS
    Imports GitHub Copilot chat history into VS Code workspaceStorage.
.DESCRIPTION
    Extracts the migration zip, matches exported workspaces to local ones,
    allows manual mapping for unmatched projects, and imports chat data.
.NOTES
    Run this script on your NEW PC.
    Make sure VS Code is CLOSED before running this script.
#>

[CmdletBinding()]
param(
    [string]$ZipPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# If no zip path provided, show Open File dialog
if (-not $ZipPath) {
    Add-Type -AssemblyName System.Windows.Forms
    $openDialog = [System.Windows.Forms.OpenFileDialog]::new()
    $openDialog.Title = "Select Copilot Chat Export File"
    $openDialog.Filter = "ZIP files (*.zip)|*.zip"
    $openDialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    
    if ($openDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ZipPath = $openDialog.FileName
    }
    else {
        Write-Host "Import cancelled." -ForegroundColor Yellow
        return
    }
}

# Check if zip file exists
if (-not (Test-Path $ZipPath)) {
    Write-Error "Migration zip file not found at: $ZipPath"
    return
}

# Path to VS Code workspaceStorage
$workspaceStoragePath = Join-Path $env:APPDATA 'Code\User\workspaceStorage'

if (-not (Test-Path $workspaceStoragePath)) {
    Write-Error "VS Code workspaceStorage not found at: $workspaceStoragePath"
    Write-Host "Make sure VS Code has been run at least once on this machine." -ForegroundColor Yellow
    return
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Copilot Chat History Importer" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "IMPORTANT: Make sure VS Code is CLOSED!" -ForegroundColor Yellow
Write-Host ""
$confirm = Read-Host "Is VS Code closed? (Y/N)"
if ($confirm -notmatch '^[Yy]') {
    Write-Host "Please close VS Code and run this script again." -ForegroundColor Red
    return
}

# Function to parse workspace info
function Get-WorkspaceInfo {
    param([string]$RawUri)
    
    $decoded = [Uri]::UnescapeDataString($RawUri)
    $type = 'Local'
    $hostName = 'Local'
    $pathPart = $decoded -replace '^file:///', ''
    
    if ($decoded -match '^vscode-remote://wsl\+(?<D>[^/]+)(?<R>/.*)') {
        $type = 'WSL'
        $hostName = "WSL: $($Matches.D)"
        $pathPart = $Matches.R
    }
    elseif ($decoded -match '^vscode-remote://ssh-remote\+(?<H>[^/]+)(?<R>/.*)') {
        $type = 'SSH'
        $hostName = "SSH: $($Matches.H)"
        $pathPart = $Matches.R
    }
    elseif ($decoded -match '^vscode-remote://dev-container\+(?<C>[^/]+)(?<R>/.*)') {
        $type = 'DevContainer'
        $hostName = 'Container'
        $pathPart = $Matches.R
    }
    elseif ($decoded -match '^vscode-remote://amlext\+') {
        $type = 'AzureML'
        $hostName = 'AzureML'
    }
    
    $pathPart = $pathPart.TrimEnd('/')
    $project = Split-Path $pathPart -Leaf
    $repo = Split-Path (Split-Path $pathPart -Parent) -Leaf
    
    return @{
        RawUri   = $RawUri
        Type     = $type
        Host     = $hostName
        Path     = $pathPart
        Project  = $project
        Repo     = $repo
    }
}

Write-Host "Extracting migration zip..." -ForegroundColor Cyan

# Create temp directory for extraction
$tempExtractPath = Join-Path $env:TEMP "VSCode_Chats_Import_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $tempExtractPath -Force | Out-Null

# Extract zip
Expand-Archive -Path $ZipPath -DestinationPath $tempExtractPath -Force

Write-Host "Scanning local workspaces..." -ForegroundColor Cyan

# Build list of local workspaces
$localWorkspaces = Get-ChildItem $workspaceStoragePath -Directory | ForEach-Object {
    $folder = $_
    $workspaceJsonPath = Join-Path $folder.FullName 'workspace.json'
    
    if (-not (Test-Path $workspaceJsonPath)) { return }
    
    try {
        $json = Get-Content $workspaceJsonPath -Raw | ConvertFrom-Json
        $rawUri = if ($json.folder) { $json.folder } else { $json.configuration }
        
        if (-not $rawUri) { return }
        
        $info = Get-WorkspaceInfo -RawUri $rawUri
        
        [PSCustomObject]@{
            FolderPath = $folder.FullName
            RawUri     = $rawUri
            Type       = $info.Type
            Host       = $info.Host
            Path       = $info.Path
            Project    = $info.Project
            Repo       = $info.Repo
        }
    }
    catch { }
} | Where-Object { $_ }

Write-Host "Found $($localWorkspaces.Count) local workspace(s)." -ForegroundColor Gray

Write-Host "Analyzing exported workspaces..." -ForegroundColor Cyan

# Build list of exported workspaces with match status
$exportedFolders = Get-ChildItem -Path $tempExtractPath -Directory
$exportedWorkspaces = @()

foreach ($folder in $exportedFolders) {
    $workspaceJsonPath = Join-Path $folder.FullName 'workspace.json'
    
    if (-not (Test-Path $workspaceJsonPath)) { continue }
    
    try {
        $json = Get-Content $workspaceJsonPath -Raw | ConvertFrom-Json
        $rawUri = if ($json.folder) { $json.folder } else { $json.configuration }
        
        if (-not $rawUri) { continue }
        
        $info = Get-WorkspaceInfo -RawUri $rawUri
        
        # Try exact match
        $match = $localWorkspaces | Where-Object { $_.RawUri -eq $rawUri } | Select-Object -First 1
        
        $exportedWorkspaces += [PSCustomObject]@{
            ExportedFolder = $folder.FullName
            RawUri         = $rawUri
            Repo           = $info.Repo
            Project        = $info.Project
            Host           = $info.Host
            Type           = $info.Type
            Path           = $info.Path
            Status         = if ($match) { "✓ Matched" } else { "⚠ No match" }
            TargetFolder   = if ($match) { $match.FolderPath } else { $null }
            TargetPath     = if ($match) { $match.Path } else { $null }
        }
    }
    catch {
        Write-Warning "Failed to parse: $($folder.Name)"
    }
}

if ($exportedWorkspaces.Count -eq 0) {
    Write-Warning "No valid workspaces found in the export."
    Remove-Item $tempExtractPath -Recurse -Force
    return
}

# Step 1: Main grid - select what to import/map
Write-Host ""
Write-Host "Step 1: Select projects to import" -ForegroundColor Green
Write-Host "  - Select matched projects to import them" -ForegroundColor Gray
Write-Host "  - Select unmatched projects to map them manually" -ForegroundColor Gray
Write-Host "  - Don't select = skip" -ForegroundColor Gray
Write-Host ""

$selected = $exportedWorkspaces | 
    Sort-Object Status, Project |
    Select-Object Repo, Project, Host, Type, Status, Path, ExportedFolder, RawUri, TargetFolder, TargetPath |
    Out-GridView -Title "Select projects to IMPORT (matched) or MAP (unmatched). Don't select = skip." -PassThru

if (-not $selected -or $selected.Count -eq 0) {
    Write-Host "No projects selected. Exiting." -ForegroundColor Yellow
    Remove-Item $tempExtractPath -Recurse -Force
    return
}

# Separate matched and unmatched
$toImport = [System.Collections.ArrayList]@()
$toMap = @()

foreach ($item in $selected) {
    if ($item.TargetFolder) {
        [void]$toImport.Add($item)
    }
    else {
        $toMap += $item
    }
}

# Step 2: Map unmatched projects
if ($toMap.Count -gt 0) {
    Write-Host ""
    Write-Host "Step 2: Map unmatched projects" -ForegroundColor Green
    Write-Host "  $($toMap.Count) project(s) need manual mapping." -ForegroundColor Gray
    Write-Host ""
    
    # Get list of local workspaces not already used as targets
    $usedTargets = @($toImport | ForEach-Object { $_.TargetFolder })
    
    $counter = 0
    foreach ($item in $toMap) {
        $counter++
        Write-Host "[$counter/$($toMap.Count)] Mapping: $($item.Project) ($($item.Host))" -ForegroundColor Cyan
        Write-Host "          Original: $($item.Path)" -ForegroundColor DarkGray
        
        # Sort local workspaces by similarity
        $availableTargets = $localWorkspaces | 
            Where-Object { $_.FolderPath -notin $usedTargets } |
            ForEach-Object {
                $similarity = 0
                if ($_.Project -eq $item.Project) { $similarity += 100 }  # Same name = top
                if ($_.Type -eq $item.Type) { $similarity += 50 }          # Same type = next
                if ($_.Repo -eq $item.Repo) { $similarity += 25 }          # Same repo = bonus
                
                $_ | Add-Member -NotePropertyName Similarity -NotePropertyValue $similarity -PassThru
            } |
            Sort-Object Similarity -Descending |
            Select-Object Project, Repo, Host, Type, Path, FolderPath
        
        if ($availableTargets.Count -eq 0) {
            Write-Host "          No available targets. Skipping." -ForegroundColor Yellow
            continue
        }
        
        $picked = $availableTargets | 
            Out-GridView -Title "[$counter/$($toMap.Count)] Pick target for '$($item.Project)' - sorted by similarity (close to skip)" -PassThru
        
        if ($picked) {
            # Add to import list with the picked target
            $item.TargetFolder = $picked.FolderPath
            $item.TargetPath = $picked.Path
            [void]$toImport.Add($item)
            $usedTargets += $picked.FolderPath
            Write-Host "          → Mapped to: $($picked.Path)" -ForegroundColor Green
        }
        else {
            Write-Host "          → Skipped" -ForegroundColor Yellow
        }
    }
}

# Step 3: Summary
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  IMPORT SUMMARY" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

if ($toImport.Count -gt 0) {
    Write-Host "  Will import ($($toImport.Count)):" -ForegroundColor Green
    foreach ($item in $toImport) {
        $localMatch = $localWorkspaces | Where-Object { $_.FolderPath -eq $item.TargetFolder }
        $mapType = if ($localMatch -and $localMatch.RawUri -eq $item.RawUri) { "matched" } else { "mapped" }
        Write-Host "    $($item.Project.PadRight(20)) → $($item.TargetPath) ($mapType)" -ForegroundColor White
    }
}
else {
    Write-Host "  Nothing to import." -ForegroundColor Yellow
    Remove-Item $tempExtractPath -Recurse -Force
    return
}

$skippedCount = $exportedWorkspaces.Count - $toImport.Count
if ($skippedCount -gt 0) {
    Write-Host ""
    Write-Host "  Skipped ($skippedCount):" -ForegroundColor Yellow
    $skippedItems = $exportedWorkspaces | Where-Object { 
        $_.ExportedFolder -notin ($toImport | ForEach-Object { $_.ExportedFolder })
    }
    foreach ($item in $skippedItems) {
        Write-Host "    $($item.Project) ($($item.Host))" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Step 4: Confirm
$proceed = Read-Host "Proceed with import? (Y/N)"
if ($proceed -notmatch '^[Yy]') {
    Write-Host "Import cancelled." -ForegroundColor Yellow
    Remove-Item $tempExtractPath -Recurse -Force
    return
}

# Step 5: Import
Write-Host ""
if ($DryRun) {
    Write-Host "[DRY RUN] Simulating import..." -ForegroundColor Magenta
} else {
    Write-Host "Importing..." -ForegroundColor Cyan
}

$successCount = 0
foreach ($item in $toImport) {
    Write-Host "  [$($successCount + 1)/$($toImport.Count)] $($item.Project)..." -ForegroundColor Gray -NoNewline
    
    try {
        if ($DryRun) {
            Write-Host " [DRY RUN] Would copy to: $($item.TargetFolder)" -ForegroundColor Magenta
        }
        else {
            # Copy all files except workspace.json
            $filesToCopy = Get-ChildItem -Path $item.ExportedFolder -File | 
                           Where-Object { $_.Name -ne 'workspace.json' }
            
            foreach ($file in $filesToCopy) {
                Copy-Item -Path $file.FullName -Destination $item.TargetFolder -Force
            }
            
            # Copy subdirectories (like chatSessions)
            $subDirs = Get-ChildItem -Path $item.ExportedFolder -Directory
            foreach ($subDir in $subDirs) {
                $destSubDir = Join-Path $item.TargetFolder $subDir.Name
                Copy-Item -Path $subDir.FullName -Destination $destSubDir -Recurse -Force
            }
            
            Write-Host " OK" -ForegroundColor Green
        }
        
        $successCount++
    }
    catch {
        Write-Host " FAILED: $_" -ForegroundColor Red
    }
}

# Cleanup temp folder
Remove-Item $tempExtractPath -Recurse -Force

# Step 6: Done
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "[DRY RUN] Complete!" -ForegroundColor Magenta
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Would import: $successCount project(s)" -ForegroundColor Magenta
    Write-Host "  Skipped:      $skippedCount project(s)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Run without -DryRun to actually import." -ForegroundColor Yellow
}
else {
    Write-Host "Import Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Imported: $successCount project(s)" -ForegroundColor Green
    Write-Host "  Skipped:  $skippedCount project(s)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "You can now open VS Code and check your Copilot chat history!" -ForegroundColor Green
}
