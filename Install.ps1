<#
.SYNOPSIS
    Creates the desktop shortcut (opens the tracker) and a Startup shortcut (syncs at Windows logon).
    Run again after moving the folder. Use -Uninstall to remove both shortcuts.
#>
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$script  = Join-Path $PSScriptRoot 'Spooldex.ps1'
$desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Spooldex.lnk'
$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Spooldex Sync.lnk'

# Shortcuts from before the project was renamed to Spooldex.
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Filament Tracker.lnk'),
            (Join-Path ([Environment]::GetFolderPath('Startup')) 'Filament Tracker Sync.lnk') -ErrorAction SilentlyContinue

if ($Uninstall) {
    Remove-Item $desktop, $startup -ErrorAction SilentlyContinue
    Write-Host 'Shortcuts removed.'
    return
}

$shell = New-Object -ComObject WScript.Shell
function New-Shortcut([string]$Path, [string]$Arguments, [string]$Description) {
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" $Arguments".Trim()
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.Description = $Description
    $lnk.IconLocation = "$(Join-Path $PSScriptRoot 'assets\icon.ico'),0"
    $lnk.WindowStyle = 7   # minimized
    $lnk.Save()
}

New-Shortcut $desktop '' 'Open Spooldex'
New-Shortcut $startup '-SyncOnly' 'Sync Bambu prints into Spooldex at logon'
Write-Host "Created: $desktop"
Write-Host "Created: $startup"
