#Requires -Version 7.5
<#
.SYNOPSIS
    Imports GitHub Copilot chat history into VS Code workspaceStorage.
.DESCRIPTION
    Extracts the migration zip, reads workspace.json from each exported folder,
    finds matching workspaces on the current machine, and copies the chat data.
    Optimized for PowerShell 7 with parallel processing.
.NOTES
    Run this script on your NEW PC.
    Make sure VS Code is CLOSED before running this script.
    Open each project in VS Code at least once before running to generate workspace IDs.
#>

[CmdletBinding()]
param(
    [string]$ZipPath = "C:\d\dev\CopilotChatsMigration\VSCode_Chats_Migration.zip"
)

$ErrorActionPreference = 'Stop'

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
Write-Host "IMPORTANT: Make sure VS Code is CLOSED before proceeding!" -ForegroundColor Yellow
Write-Host ""
$confirm = Read-Host "Is VS Code closed? (Y/N)"
if ($confirm -notmatch '^[Yy]') {
    Write-Host "Please close VS Code and run this script again." -ForegroundColor Red
    return
}

# Function to extract display info from path
function Get-WorkspaceDisplayInfo {
    param([string]$RawUri)
    
    $decoded = [Uri]::UnescapeDataString($RawUri)
    
    $info = @{
        DisplayPath = $decoded
        Type        = 'Unknown'
        Host        = 'Local'
        ProjectName = ''
    }
    
    if ($decoded -match '^vscode-remote://wsl\+([^/]+)(.*)$') {
        $info.Type = 'WSL'
        $info.Host = "WSL: $($Matches[1])"
        $pathPart = $Matches[2]
    }
    elseif ($decoded -match '^vscode-remote://ssh-remote\+([^/]+)(.*)$') {
        $info.Type = 'SSH'
        $info.Host = "SSH: $($Matches[1])"
        $pathPart = $Matches[2]
    }
    elseif ($decoded -match '^vscode-remote://dev-container\+([^/]+)(.*)$') {
        $info.Type = 'DevContainer'
        $info.Host = "Container"
        $pathPart = $Matches[2]
    }
    elseif ($decoded -match '^file:///(.+)$') {
        $info.Type = 'Local'
        $info.Host = 'Local'
        $pathPart = $Matches[1]
    }
    else {
        $pathPart = $decoded
    }
    
    $pathPart = $pathPart.TrimEnd('/')
    $segments = $pathPart -split '/'
    $segments = $segments | Where-Object { $_ -ne '' }
    
    if ($segments.Count -ge 1) {
        $info.ProjectName = $segments[-1]
    }
    
    $info.DisplayPath = $pathPart
    
    return $info
}

Write-Host "Extracting migration zip..." -ForegroundColor Cyan

# Create temp directory for extraction
$tempExtractPath = Join-Path $env:TEMP "VSCode_Chats_Import_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $tempExtractPath -Force | Out-Null

# Extract zip
Expand-Archive -Path $ZipPath -DestinationPath $tempExtractPath -Force

Write-Host "Building index of local workspaces..." -ForegroundColor Cyan

# Build index of current machine's workspaces
$localWorkspaces = @{}

$localFolders = Get-ChildItem -Path $workspaceStoragePath -Directory

# Build index using parallel processing (PS7)
$localWorkspacesList = $localFolders | ForEach-Object -Parallel {
    $folder = $_
    $workspaceJsonPath = Join-Path $folder.FullName 'workspace.json'
    
    if (-not (Test-Path $workspaceJsonPath)) {
        return
    }
    
    try {
        $workspaceJson = Get-Content $workspaceJsonPath -Raw | ConvertFrom-Json
        $projectUri = $workspaceJson.folder ?? $workspaceJson.configuration
        
        if ($projectUri) {
            [PSCustomObject]@{
                NormalizedPath = $projectUri
                FolderPath     = $folder.FullName
                FolderID       = $folder.Name
            }
        }
    }
    catch {
        # Silently skip problematic folders
    }
} -ThrottleLimit 10 | Where-Object { $_ }

# Convert to hashtable for fast lookups
foreach ($ws in $localWorkspacesList) {
    $localWorkspaces[$ws.NormalizedPath] = $ws.FolderPath
}

Write-Host "Found $($localWorkspaces.Count) workspace(s) on this machine." -ForegroundColor Gray
Write-Host ""
Write-Host "Importing exported workspaces..." -ForegroundColor Cyan
Write-Host ""

# Process each exported folder
$exportedFolders = Get-ChildItem -Path $tempExtractPath -Directory
$successCount = 0
$warningCount = 0
$notFoundProjects = @()

foreach ($exportedFolder in $exportedFolders) {
    $workspaceJsonPath = Join-Path $exportedFolder.FullName 'workspace.json'
    
    if (-not (Test-Path $workspaceJsonPath)) {
        continue
    }
    
    try {
        $workspaceJson = Get-Content $workspaceJsonPath -Raw | ConvertFrom-Json
        $projectUri = $workspaceJson.folder ?? $workspaceJson.configuration
        
        if (-not $projectUri) {
            continue
        }
        
        $displayInfo = Get-WorkspaceDisplayInfo -RawUri $projectUri
        $targetFolderPath = $localWorkspaces[$projectUri]
        
        if ($targetFolderPath) {
            # Found a match - do the import
            Write-Host "[SUCCESS] " -ForegroundColor Green -NoNewline
            Write-Host "$($displayInfo.ProjectName) " -ForegroundColor White -NoNewline
            Write-Host "($($displayInfo.Host))" -ForegroundColor Gray
            
            # Copy all files from exported folder to target, excluding workspace.json
            $filesToCopy = Get-ChildItem -Path $exportedFolder.FullName -File | 
                           Where-Object { $_.Name -ne 'workspace.json' }
            
            foreach ($file in $filesToCopy) {
                Copy-Item -Path $file.FullName -Destination $targetFolderPath -Force
            }
            
            # Copy subdirectories (like chatSessions)
            $subDirs = Get-ChildItem -Path $exportedFolder.FullName -Directory
            foreach ($subDir in $subDirs) {
                $destSubDir = Join-Path $targetFolderPath $subDir.Name
                Copy-Item -Path $subDir.FullName -Destination $destSubDir -Recurse -Force
            }
            
            $successCount++
        }
        else {
            # No match found
            Write-Host "[WARNING] " -ForegroundColor Yellow -NoNewline
            Write-Host "No match: " -ForegroundColor White -NoNewline
            Write-Host "$($displayInfo.ProjectName) " -ForegroundColor Cyan -NoNewline
            Write-Host "($($displayInfo.Host))" -ForegroundColor Gray
            
            $warningCount++
            $notFoundProjects += [PSCustomObject]@{
                Project = $displayInfo.ProjectName
                Host    = $displayInfo.Host
                Path    = $displayInfo.DisplayPath
            }
        }
    }
    catch {
        Write-Warning "Failed to process: $($exportedFolder.Name) - $_"
    }
}

# Cleanup temp folder
Remove-Item $tempExtractPath -Recurse -Force

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Import Complete!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Results:" -ForegroundColor White
Write-Host "  Successful imports: " -NoNewline
Write-Host "$successCount" -ForegroundColor Green
Write-Host "  No match found:     " -NoNewline
Write-Host "$warningCount" -ForegroundColor Yellow
Write-Host ""

if ($warningCount -gt 0) {
    Write-Host "Projects that need to be opened in VS Code first:" -ForegroundColor Yellow
    foreach ($proj in $notFoundProjects) {
        Write-Host "  - $($proj.Project) ($($proj.Host))" -ForegroundColor Gray
        Write-Host "    Path: $($proj.Path)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "Steps to import these:" -ForegroundColor Yellow
    Write-Host "  1. Open each project in VS Code (creates the workspace ID)" -ForegroundColor Gray
    Write-Host "  2. Close VS Code" -ForegroundColor Gray
    Write-Host "  3. Run this import script again" -ForegroundColor Gray
    Write-Host ""
}

Write-Host "You can now open VS Code and check your Copilot chat history!" -ForegroundColor Green
