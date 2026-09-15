# Tableau MCP setup for Claude Desktop

This sets up **two** separate MCP servers so Claude Desktop can both query Tableau data
and read Tableau's Metadata API (GraphQL) for lineage/calc-formula lookups:

| Server name       | Project                                                              | What it's for |
|--------------------|-----------------------------------------------------------------------|----------------|
| `tableau`          | [tableau/tableau-mcp](https://github.com/tableau/tableau-mcp) (official) | VizQL data queries, list workbooks/datasources, basic field metadata |
| `tableau-graphql`  | [`tableau-graphql-mcp`](https://pypi.org/project/tableau-graphql-mcp) (third-party) | Raw GraphQL passthrough to `/api/metadata/graphql` — lineage, calculated-field formulas, impact analysis |

They're independent codebases with **different environment variable names** for the
same credentials. That mismatch was the main source of pain when setting this up —
see the troubleshooting table below.

## Prerequisites

- Node.js 18+
- Python 3.10+
- Git
- A Tableau **Personal Access Token** (Tableau Cloud/Server → Account Settings →
  Personal Access Tokens). PATs expire after ~15 days of non-use by default.

## Quick start

**Windows (PowerShell):**
```powershell
.\setup-tableau-mcp.ps1 -TableauServer "https://YOUR-POD.online.tableau.com" -TableauSite "yoursite" -PatName "your-pat-name"
```

**macOS/Linux (bash):**
```bash
chmod +x setup-tableau-mcp.sh
./setup-tableau-mcp.sh -s "https://YOUR-POD.online.tableau.com" -t "yoursite" -p "your-pat-name"
```
Run `./setup-tableau-mcp.sh -h` for all options (custom install dirs, etc.).

You'll be prompted for the PAT secret interactively (hidden input) — it's never
written into either script or committed anywhere. Both scripts will:

1. Clone + build the official `tableau-mcp` (Node) into `C:\_dev\tableau-mcp`
2. Create an isolated Python venv and install `tableau-graphql-mcp` pinned to `mcp<2`
3. Back up your existing `claude_desktop_config.json`
4. Merge both server entries into it with the correct env var names for each
5. Print next steps

After it finishes: **fully quit Claude Desktop, reopen it, and start a brand-new
conversation** before testing (see below for why).

Config file locations (backed up automatically before either script edits it):

| OS | Path |
|---|---|
| Windows | `%APPDATA%\Claude\claude_desktop_config.json` |
| macOS | `~/Library/Application Support/Claude/claude_desktop_config.json` |
| Linux | `~/.config/Claude/claude_desktop_config.json` (may vary by build) |

## Manual config reference

If you'd rather edit `claude_desktop_config.json` by hand, the two blocks look
like this (paths shown are Windows-style — use forward-slash Unix paths like
`/home/you/dev/tableau-mcp/build/index.js` on macOS/Linux):

```json
{
  "mcpServers": {
    "tableau": {
      "command": "node",
      "args": ["C:/_dev/tableau-mcp/build/index.js"],
      "env": {
        "SERVER": "https://YOUR-POD.online.tableau.com",
        "SITE_NAME": "yoursite",
        "PAT_NAME": "your-pat-name",
        "PAT_VALUE": "your-pat-secret",
        "DATASOURCE_CREDENTIALS": "",
        "DEFAULT_LOG_LEVEL": "debug",
        "ENABLE_MCP_SITE_SETTINGS": "false",
        "INCLUDE_TOOLS": "read-metadata,query-datasource,list-workbooks"
      }
    },
    "tableau-graphql": {
      "command": "C:/Users/YOURNAME/tableau-graphql-venv/Scripts/tableau-graphql-mcp.exe",
      "env": {
        "TABLEAU_SERVER": "https://YOUR-POD.online.tableau.com",
        "TABLEAU_SITE": "yoursite",
        "TABLEAU_PAT_NAME": "your-pat-name",
        "TABLEAU_PAT_SECRET": "your-pat-secret",
        "DEFAULT_LOG_LEVEL": "debug",
        "ENABLE_MCP_SITE_SETTINGS": "false"
      }
    }
  }
}
```

**Note the credential key is different**: `PAT_VALUE` for the official server,
`TABLEAU_PAT_SECRET` for `tableau-graphql-mcp`. This was the single biggest source
of "no errors, but it just doesn't work" during setup.

## Troubleshooting checklist (issues we actually hit)

| Symptom | Cause | Fix |
|---|---|---|
| `spawn tableau-graphql-mcp ENOENT` | `pip`-installed console scripts go into Python's `Scripts\` folder, which usually isn't on PATH | Point `command` at the full path, e.g. `...\Python311\Scripts\tableau-graphql-mcp.exe`, or add `Scripts\` to PATH and restart Desktop |
| `ModuleNotFoundError: No module named 'mcp.server.fastmcp'` | `tableau-graphql-mcp` needs `mcp` SDK v1.x (`FastMCP`); a global v2.x install breaks it | Install in an isolated venv: `pip install "mcp<2" tableau-graphql-mcp` |
| Server starts clean, no errors, but Claude says it has "no Tableau credentials" in chat | Newly added/fixed MCP tools don't attach to a conversation that was already open | Start a **new** conversation after any config change + Desktop restart |
| Tool loads, but calling it returns `No credentials. Set TABLEAU_PAT_NAME + TABLEAU_PAT_SECRET...` | Config had `TABLEAU_PAT_VALUE` instead of `TABLEAU_PAT_SECRET` | Use the exact env var name the tool's own error message reports |
| `server_info` shows `"site_content_url": "(default)"` instead of your real site | Site scoping env var possibly not being read as expected | Confirm the exact var name for site scoping against the installed package version; test with a query and check results are actually scoped to your site |

## Security notes

- **Both configs store the PAT in plaintext.** Treat `claude_desktop_config.json`
  as a secret file — don't commit it, don't screen-share it unredacted.
- **Rotate the PAT** if it's ever been pasted into a chat, ticket, Slack message,
  or shared screen. Tableau Account Settings → Personal Access Tokens → revoke,
  then create a new one and update both blocks above.
- If your org locks down Claude Desktop's Developer/MCP settings, an org owner
  will need to allow local MCP servers before this works at all.
