# Copilot Chats Migration

Migrate GitHub Copilot chat history between PCs.

## The Problem

VS Code stores Copilot chat history in `%APPDATA%\Code\User\workspaceStorage` in folders named with random hashes. These hashes are derived from the project path, so you can't just copy folders between machines if paths change.

## Solution

These scripts match workspaces by their **internal project path** (stored in `workspace.json`), not by folder hash.

For **mapped** (non-exact) workspaces, the import script automatically updates file path references inside chat session JSON files so VS Code can properly load them.

## Scripts

### Export-CopilotChats.ps1 (Run on OLD PC)

1. Scans workspaceStorage folders
2. Shows a grid to select which projects to export
3. Creates a zip file with selected workspaces

```powershell
# Interactive - opens Save dialog
.\Export-CopilotChats.ps1

# Or specify output path
.\Export-CopilotChats.ps1 -OutputPath "D:\backup\chats.zip"
```

### Import-CopilotChats.ps1 (Run on NEW PC)

1. Extracts the zip
2. Matches exported projects to local workspaces by exact path
3. For unmatched: lets you manually pick a target (sorted by similarity)
4. Shows summary and asks for confirmation
5. Copies chat data into target folders (updates paths for mapped workspaces)

```powershell
# Interactive - opens file picker
.\Import-CopilotChats.ps1

# Or specify zip path
.\Import-CopilotChats.ps1 -ZipPath "D:\backup\chats.zip"

# Dry run - see what would happen without copying
.\Import-CopilotChats.ps1 -ZipPath "D:\backup\chats.zip" -DryRun
```

## Requirements

- PowerShell 7.5+
- VS Code must be **closed** during import

## Supported Workspace Types

- Local folders
- WSL (Windows Subsystem for Linux)
- SSH Remote
- Dev Containers
- Azure ML

## How Matching Works

| Old PC Path | New PC Path | Match? |
|-------------|-------------|--------|
| `wsl+ubuntu/home/user/project` | `wsl+ubuntu/home/user/project` | ✓ Exact |
| `wsl+ubuntu-22.04/home/old/project` | `wsl+ubuntu-24.04/home/new/project` | ✗ Manual mapping needed |
| `file:///c:/dev/project` | `file:///d:/work/project` | ✗ Manual mapping needed |

For unmatched projects, the import script shows all local workspaces sorted by similarity (same project name first, then same type).

## What Gets Copied

- `state.vscdb` - Main chat history database
- `chatSessions/` - Additional chat data (with path fixes for mapped workspaces)
- Other workspace state files

**Not copied:** `workspace.json` (kept from target to preserve local hash)

## Troubleshooting

### "Ghost Chats" - Chats appear but won't load when clicked

This happens when the internal file references in chat sessions point to paths that don't exist on the new machine. The updated import script should handle this automatically for mapped workspaces.

**If you still see ghost chats:**

1. **Check Developer Tools** for the specific error:
   - In VS Code: Help → Toggle Developer Tools → Console tab
   - Click the ghost chat to see the error message

2. **Use VS Code's built-in import** as a fallback:
   - Open Command Palette (`Ctrl+Shift+P`)
   - Run `Chat: Import Chat...`
   - Navigate to `%APPDATA%\Code\User\workspaceStorage\[hash]\chatSessions`
   - Select individual `.json` files to import

3. **Read chats directly** as raw JSON:
   - Open the `.json` files from `chatSessions` folder in VS Code
   - Use `Ctrl+F` to search for your code snippets
