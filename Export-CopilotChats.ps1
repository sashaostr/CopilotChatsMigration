#Requires -Version 7.5
<#
.SYNOPSIS
    Exports GitHub Copilot chat history from VS Code workspaceStorage.
.DESCRIPTION
    Scans workspaceStorage folders, parses workspace.json to identify projects,
    displays them in a grid for selection, and exports selected folders to a zip file.
    Optimized for PowerShell 7 with parallel processing.
.NOTES
    Run this script on your OLD PC.
#>

[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# If no output path provided, show Save File dialog
if (-not $OutputPath) {
    Add-Type -AssemblyName System.Windows.Forms
    $saveDialog = [System.Windows.Forms.SaveFileDialog]::new()
    $saveDialog.Title = "Save Copilot Chat Export"
    $saveDialog.Filter = "ZIP files (*.zip)|*.zip"
    $saveDialog.FileName = "VSCode_Chats_Migration.zip"
    $saveDialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    
    if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $OutputPath = $saveDialog.FileName
    }
    else {
        Write-Host "Export cancelled." -ForegroundColor Yellow
        return
    }
}

# Path to VS Code workspaceStorage
$workspaceStoragePath = Join-Path $env:APPDATA 'Code\User\workspaceStorage'

if (-not (Test-Path $workspaceStoragePath)) {
    Write-Error "VS Code workspaceStorage not found at: $workspaceStoragePath"
    return
}

Write-Host "Scanning workspaceStorage at: $workspaceStoragePath" -ForegroundColor Cyan

# Collect all workspace information
$workspaces = Get-ChildItem $workspaceStoragePath -Directory | ForEach-Object {
    $folder = $_
    $workspaceJsonPath = Join-Path $folder.FullName 'workspace.json'
    
    if (-not (Test-Path $workspaceJsonPath)) { return }
    
    try {
        $json = Get-Content $workspaceJsonPath -Raw | ConvertFrom-Json
        $rawUri = if ($json.folder) { $json.folder } else { $json.configuration }
        
        if (-not $rawUri) { return }
        
        $decoded = [Uri]::UnescapeDataString($rawUri)
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
            # Keep pathPart as is for AML
        }
        
        $pathPart = $pathPart.TrimEnd('/')
        $project = Split-Path $pathPart -Leaf
        $repo = Split-Path (Split-Path $pathPart -Parent) -Leaf
        
        # Check for chat data
        $stateDbPath = Join-Path $folder.FullName 'state.vscdb'
        $chatSessionsPath = Join-Path $folder.FullName 'chatSessions'
        $hasChatData = (Test-Path $stateDbPath) -or (Test-Path $chatSessionsPath)
        
        # Get dates - check state.vscdb for last use time
        $lastUsed = if (Test-Path $stateDbPath) { 
            (Get-Item $stateDbPath).LastWriteTime 
        } else { 
            $folder.LastWriteTime 
        }
        
        [PSCustomObject]@{
            Repo         = $repo
            Subproject   = $project
            Host         = $hostName
            Type         = $type
            Path         = $pathPart
            ID           = $folder.Name
            HasChatData  = $hasChatData
            Created      = $folder.CreationTime.ToString('yyyy-MM-dd HH:mm')
            LastUsed     = $lastUsed.ToString('yyyy-MM-dd HH:mm')
            FolderPath   = $folder.FullName
            RawUri       = $rawUri
        }
    }
    catch {
        # Skip problematic folders
    }
} | Where-Object { $_ }

if ($workspaces.Count -eq 0) {
    Write-Warning "No valid workspaces found."
    return
}

Write-Host "Found $($workspaces.Count) workspace(s). Opening selection grid..." -ForegroundColor Green

# Display grid for selection
$selected = $workspaces | 
    Sort-Object LastUsed -Descending |
    Select-Object Repo, Subproject, Host, Type, HasChatData, Created, LastUsed, Path, ID, FolderPath, RawUri |
    Out-GridView -Title "Select Workspaces to Export (Ctrl+Click to select multiple, then click OK)" -PassThru

if (-not $selected -or $selected.Count -eq 0) {
    Write-Host "No workspaces selected. Exiting." -ForegroundColor Yellow
    return
}

Write-Host "Selected $($selected.Count) workspace(s) for export." -ForegroundColor Cyan

# Create temp directory for export
$tempExportPath = Join-Path $env:TEMP "VSCode_Chats_Export_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $tempExportPath -Force | Out-Null

Write-Host "Copying selected workspaces to temp folder..." -ForegroundColor Cyan

foreach ($ws in $selected) {
    $sourcePath = $ws.FolderPath
    $destPath = Join-Path $tempExportPath $ws.ID
    
    Write-Host "  Copying: $($ws.Subproject) ($($ws.Host))..." -ForegroundColor Gray
    
    # Copy the entire folder
    Copy-Item -Path $sourcePath -Destination $destPath -Recurse -Force
}

# Remove existing zip if present
if (Test-Path $OutputPath) {
    Remove-Item $OutputPath -Force
}

Write-Host "Creating zip archive at: $OutputPath" -ForegroundColor Cyan

# Create zip file
Compress-Archive -Path "$tempExportPath\*" -DestinationPath $OutputPath -CompressionLevel Optimal

# Cleanup temp folder
Remove-Item $tempExportPath -Recurse -Force

$zipSize = [math]::Round((Get-Item $OutputPath).Length / 1MB, 2)

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "Export Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Exported $($selected.Count) workspace(s)"
Write-Host "Output file: $OutputPath"
Write-Host "File size: $zipSize MB"
Write-Host "`nCopy this zip file to your new PC and run the Import script." -ForegroundColor Yellow
