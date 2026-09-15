<#
.SYNOPSIS
  Sets up two Tableau MCP servers for Claude Desktop:
    1. "tableau"          - official tableau/tableau-mcp (VizQL query, list-workbooks, etc.)
    2. "tableau-graphql"  - third-party tableau-graphql-mcp (raw Metadata API / GraphQL passthrough)

.NOTES
  - Your Personal Access Token (PAT) is entered interactively, never hard-coded here.
  - The token still ends up in plaintext in claude_desktop_config.json (both servers require
    that, there's no way around it with these tools). Treat that file as a secret. Restrict
    its permissions and rotate the PAT periodically.
  - Run this from a normal PowerShell window (not as admin unless your machine requires it
    for npm/pip global installs).

.PARAMETER TableauServer
  Base URL of your Tableau Cloud/Server pod, e.g. https://dub01.online.tableau.com

.PARAMETER TableauSite
  The site's contentUrl (the part after /site/ in your Tableau URLs), e.g. casumo

.PARAMETER PatName
  The name of your Tableau Personal Access Token (created under Account Settings > PATs)

.PARAMETER OfficialMcpDir
  Where to clone/build the official tableau-mcp repo. Defaults to C:\_dev\tableau-mcp

.PARAMETER VenvDir
  Where to create the Python venv for tableau-graphql-mcp. Defaults to
  $env:USERPROFILE\tableau-graphql-venv

.EXAMPLE
  .\setup-tableau-mcp.ps1 -TableauServer "https://dub01.online.tableau.com" -TableauSite "casumo" -PatName "tableau_yourname"
#>

param(
    [Parameter(Mandatory = $true)][string]$TableauServer,
    [Parameter(Mandatory = $true)][string]$TableauSite,
    [Parameter(Mandatory = $true)][string]$PatName,
    [string]$OfficialMcpDir = "C:\_dev\tableau-mcp",
    [string]$VenvDir = "$env:USERPROFILE\tableau-graphql-venv"
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "!! $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# 0. Prereq checks
# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites"

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw "Node.js not found on PATH. Install Node 18+ before continuing." }
Write-Host "Node found: $($node.Source)"

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { throw "Python not found on PATH. Install Python 3.10+ before continuing." }
Write-Host "Python found: $($python.Source)"

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { throw "git not found on PATH. Install Git for Windows before continuing." }

# ---------------------------------------------------------------------------
# 1. Official tableau-mcp (Node)
# ---------------------------------------------------------------------------
Write-Step "Setting up official tableau-mcp"

if (-not (Test-Path $OfficialMcpDir)) {
    git clone https://github.com/tableau/tableau-mcp.git $OfficialMcpDir
} else {
    Write-Host "Directory already exists, skipping clone: $OfficialMcpDir"
}

Push-Location $OfficialMcpDir
npm install
npm run build
Pop-Location

$officialEntryPoint = Join-Path $OfficialMcpDir "build\index.js"
if (-not (Test-Path $officialEntryPoint)) {
    throw "Build did not produce $officialEntryPoint - check npm run build output above."
}
Write-Host "Official server built at: $officialEntryPoint"

# ---------------------------------------------------------------------------
# 2. tableau-graphql-mcp (Python, isolated venv)
#    NOTE: this package depends on mcp SDK v1.x (FastMCP). If your machine has
#    mcp v2.x installed globally, running it outside a venv will fail with:
#      ModuleNotFoundError: No module named 'mcp.server.fastmcp'
#    Isolating it in its own venv avoids fighting with other MCP tools that need v2.
# ---------------------------------------------------------------------------
Write-Step "Setting up tableau-graphql-mcp (isolated venv, pinned to mcp<2)"

if (-not (Test-Path $VenvDir)) {
    python -m venv $VenvDir
} else {
    Write-Host "Venv already exists, skipping creation: $VenvDir"
}

$venvPip = Join-Path $VenvDir "Scripts\pip.exe"
$venvExe = Join-Path $VenvDir "Scripts\tableau-graphql-mcp.exe"

& $venvPip install "mcp<2" tableau-graphql-mcp

if (-not (Test-Path $venvExe)) {
    throw "Install did not produce $venvExe - check pip output above."
}
Write-Host "tableau-graphql-mcp installed at: $venvExe"

# ---------------------------------------------------------------------------
# 3. Collect the PAT secret (not stored in this script or on disk anywhere else)
# ---------------------------------------------------------------------------
Write-Step "Enter your Tableau Personal Access Token secret"
Write-Warn2 "This will be written in PLAINTEXT into claude_desktop_config.json."
Write-Warn2 "Both MCP servers require this - there's no supported way to avoid it today."
$secureSecret = Read-Host -AsSecureString "PAT secret for '$PatName'"
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
$patSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

# ---------------------------------------------------------------------------
# 4. Merge into claude_desktop_config.json
# ---------------------------------------------------------------------------
Write-Step "Updating Claude Desktop config"

$configPath = Join-Path $env:APPDATA "Claude\claude_desktop_config.json"
if (-not (Test-Path $configPath)) {
    throw "Could not find $configPath - open Claude Desktop at least once first, or adjust this script's path."
}

$backupPath = "$configPath.bak.$(Get-Date -Format yyyyMMdd_HHmmss)"
Copy-Item $configPath $backupPath
Write-Host "Backed up existing config to: $backupPath"

$config = Get-Content $configPath -Raw | ConvertFrom-Json

if (-not $config.mcpServers) {
    $config | Add-Member -MemberType NoteProperty -Name mcpServers -Value ([PSCustomObject]@{})
}

# Official server entry
$config.mcpServers | Add-Member -MemberType NoteProperty -Name "tableau" -Force -Value ([PSCustomObject]@{
    command = "node"
    args    = @($officialEntryPoint)
    env     = [PSCustomObject]@{
        SERVER                    = $TableauServer
        SITE_NAME                 = $TableauSite
        PAT_NAME                  = $PatName
        PAT_VALUE                 = $patSecret
        DATASOURCE_CREDENTIALS    = ""
        DEFAULT_LOG_LEVEL         = "debug"
        ENABLE_MCP_SITE_SETTINGS  = "false"
        INCLUDE_TOOLS             = "read-metadata,query-datasource,list-workbooks"
    }
})

# tableau-graphql-mcp entry - note the DIFFERENT env var names vs the official server:
# TABLEAU_PAT_SECRET (not PAT_VALUE) is what this package expects.
$config.mcpServers | Add-Member -MemberType NoteProperty -Name "tableau-graphql" -Force -Value ([PSCustomObject]@{
    command = $venvExe
    env     = [PSCustomObject]@{
        TABLEAU_SERVER           = $TableauServer
        TABLEAU_SITE             = $TableauSite
        TABLEAU_PAT_NAME         = $PatName
        TABLEAU_PAT_SECRET       = $patSecret
        DEFAULT_LOG_LEVEL        = "debug"
        ENABLE_MCP_SITE_SETTINGS = "false"
    }
})

$config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
Write-Host "Config written to: $configPath"

# Clear the secret from memory as best-effort
$patSecret = $null
[System.GC]::Collect()

# ---------------------------------------------------------------------------
# 5. Done
# ---------------------------------------------------------------------------
Write-Step "Setup complete"
Write-Host @"

Next steps:
  1. Fully quit Claude Desktop (check it's not still running in the system tray).
  2. Reopen Claude Desktop.
  3. Start a NEW conversation (existing chats won't pick up newly added tools).
  4. Ask Claude to call the Tableau tools, e.g. "check the Tableau connection".

If something doesn't connect, check the logs at:
  %APPDATA%\Claude\logs\mcp*.log

See the accompanying README.md for a troubleshooting checklist covering the
issues we hit while building this (PATH errors, dependency conflicts, wrong
env var names, and the new-chat requirement).
"@
