#!/usr/bin/env bash
#
# setup-tableau-mcp.sh
#
# Sets up two Tableau MCP servers for Claude Desktop on macOS/Linux:
#   1. "tableau"          - official tableau/tableau-mcp (VizQL query, list-workbooks, etc.)
#   2. "tableau-graphql"  - third-party tableau-graphql-mcp (raw Metadata API / GraphQL passthrough)
#
# Your Personal Access Token (PAT) is entered interactively (hidden input), never
# hard-coded in this script. It still ends up in plaintext in claude_desktop_config.json
# (both servers require that - there's no way around it with these tools today).
# Treat that file as a secret, restrict its permissions, and rotate the PAT periodically.
#
# Usage:
#   ./setup-tableau-mcp.sh -s https://YOUR-POD.online.tableau.com -t yoursite -p your-pat-name
#
# Options:
#   -s   Tableau server URL (required)
#   -t   Tableau site content URL, i.e. the part after /site/ (required)
#   -p   PAT name (required)
#   -o   Directory to clone/build official tableau-mcp into (default: ~/dev/tableau-mcp)
#   -v   Directory for the tableau-graphql-mcp venv (default: ~/tableau-graphql-venv)

set -euo pipefail

OFFICIAL_MCP_DIR="$HOME/dev/tableau-mcp"
VENV_DIR="$HOME/tableau-graphql-venv"
TABLEAU_SERVER=""
TABLEAU_SITE=""
PAT_NAME=""

while getopts "s:t:p:o:v:h" opt; do
  case $opt in
    s) TABLEAU_SERVER="$OPTARG" ;;
    t) TABLEAU_SITE="$OPTARG" ;;
    p) PAT_NAME="$OPTARG" ;;
    o) OFFICIAL_MCP_DIR="$OPTARG" ;;
    v) VENV_DIR="$OPTARG" ;;
    h)
      grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
      exit 0
      ;;
    *) exit 1 ;;
  esac
done

if [[ -z "$TABLEAU_SERVER" || -z "$TABLEAU_SITE" || -z "$PAT_NAME" ]]; then
  echo "Missing required args. Run with -h for usage." >&2
  exit 1
fi

step()  { printf "\n\033[1;36m==> %s\033[0m\n" "$1"; }
warn()  { printf "\033[1;33m!! %s\033[0m\n" "$1"; }

# ---------------------------------------------------------------------------
# 0. Prereq checks
# ---------------------------------------------------------------------------
step "Checking prerequisites"

command -v node >/dev/null 2>&1 || { echo "Node.js not found on PATH. Install Node 18+ first." >&2; exit 1; }
echo "Node found: $(command -v node)"

command -v python3 >/dev/null 2>&1 || { echo "python3 not found on PATH. Install Python 3.10+ first." >&2; exit 1; }
echo "Python found: $(command -v python3)"

command -v git >/dev/null 2>&1 || { echo "git not found on PATH." >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Official tableau-mcp (Node)
# ---------------------------------------------------------------------------
step "Setting up official tableau-mcp"

if [[ ! -d "$OFFICIAL_MCP_DIR" ]]; then
  git clone https://github.com/tableau/tableau-mcp.git "$OFFICIAL_MCP_DIR"
else
  echo "Directory already exists, skipping clone: $OFFICIAL_MCP_DIR"
fi

(
  cd "$OFFICIAL_MCP_DIR"
  npm install
  npm run build
)

OFFICIAL_ENTRY_POINT="$OFFICIAL_MCP_DIR/build/index.js"
[[ -f "$OFFICIAL_ENTRY_POINT" ]] || { echo "Build did not produce $OFFICIAL_ENTRY_POINT" >&2; exit 1; }
echo "Official server built at: $OFFICIAL_ENTRY_POINT"

# ---------------------------------------------------------------------------
# 2. tableau-graphql-mcp (Python, isolated venv)
#    NOTE: this package depends on mcp SDK v1.x (FastMCP). If your machine has
#    mcp v2.x installed globally, running it outside a venv will fail with:
#      ModuleNotFoundError: No module named 'mcp.server.fastmcp'
#    Isolating it in its own venv avoids fighting with other MCP tools needing v2.
# ---------------------------------------------------------------------------
step "Setting up tableau-graphql-mcp (isolated venv, pinned to mcp<2)"

if [[ ! -d "$VENV_DIR" ]]; then
  python3 -m venv "$VENV_DIR"
else
  echo "Venv already exists, skipping creation: $VENV_DIR"
fi

VENV_PIP="$VENV_DIR/bin/pip"
VENV_EXE="$VENV_DIR/bin/tableau-graphql-mcp"

"$VENV_PIP" install "mcp<2" tableau-graphql-mcp

[[ -f "$VENV_EXE" ]] || { echo "Install did not produce $VENV_EXE" >&2; exit 1; }
echo "tableau-graphql-mcp installed at: $VENV_EXE"

# ---------------------------------------------------------------------------
# 3. Collect the PAT secret (hidden input, not stored anywhere by this script)
# ---------------------------------------------------------------------------
step "Enter your Tableau Personal Access Token secret"
warn "This will be written in PLAINTEXT into claude_desktop_config.json."
warn "Both MCP servers require this - there's no supported way to avoid it today."
read -r -s -p "PAT secret for '$PAT_NAME': " PAT_SECRET
echo

# ---------------------------------------------------------------------------
# 4. Merge into claude_desktop_config.json
# ---------------------------------------------------------------------------
step "Updating Claude Desktop config"

UNAME="$(uname -s)"
if [[ "$UNAME" == "Darwin" ]]; then
  CONFIG_PATH="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
else
  CONFIG_PATH="$HOME/.config/Claude/claude_desktop_config.json"
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Could not find $CONFIG_PATH - open Claude Desktop at least once first, or check the path for your platform/version." >&2
  exit 1
fi

BACKUP_PATH="${CONFIG_PATH}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG_PATH" "$BACKUP_PATH"
echo "Backed up existing config to: $BACKUP_PATH"

# Do the JSON merge in Python for reliability (avoids depending on jq being installed).
# Secret is passed via environment variable, not argv, so it doesn't show up in `ps`.
PAT_SECRET="$PAT_SECRET" \
TABLEAU_SERVER="$TABLEAU_SERVER" \
TABLEAU_SITE="$TABLEAU_SITE" \
PAT_NAME="$PAT_NAME" \
OFFICIAL_ENTRY_POINT="$OFFICIAL_ENTRY_POINT" \
VENV_EXE="$VENV_EXE" \
CONFIG_PATH="$CONFIG_PATH" \
python3 - <<'PYEOF'
import json, os

config_path = os.environ["CONFIG_PATH"]
with open(config_path) as f:
    config = json.load(f)

config.setdefault("mcpServers", {})

config["mcpServers"]["tableau"] = {
    "command": "node",
    "args": [os.environ["OFFICIAL_ENTRY_POINT"]],
    "env": {
        "SERVER": os.environ["TABLEAU_SERVER"],
        "SITE_NAME": os.environ["TABLEAU_SITE"],
        "PAT_NAME": os.environ["PAT_NAME"],
        "PAT_VALUE": os.environ["PAT_SECRET"],
        "DATASOURCE_CREDENTIALS": "",
        "DEFAULT_LOG_LEVEL": "debug",
        "ENABLE_MCP_SITE_SETTINGS": "false",
        "INCLUDE_TOOLS": "read-metadata,query-datasource,list-workbooks",
    },
}

# Note the different env var name: TABLEAU_PAT_SECRET, not PAT_VALUE.
config["mcpServers"]["tableau-graphql"] = {
    "command": os.environ["VENV_EXE"],
    "env": {
        "TABLEAU_SERVER": os.environ["TABLEAU_SERVER"],
        "TABLEAU_SITE": os.environ["TABLEAU_SITE"],
        "TABLEAU_PAT_NAME": os.environ["PAT_NAME"],
        "TABLEAU_PAT_SECRET": os.environ["PAT_SECRET"],
        "DEFAULT_LOG_LEVEL": "debug",
        "ENABLE_MCP_SITE_SETTINGS": "false",
    },
}

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
PYEOF

# Best-effort: clear the secret from this shell's environment/history
unset PAT_SECRET

echo "Config written to: $CONFIG_PATH"

# ---------------------------------------------------------------------------
# 5. Done
# ---------------------------------------------------------------------------
step "Setup complete"
cat <<EOF

Next steps:
  1. Fully quit Claude Desktop (check it's not still running in the menu bar/tray).
  2. Reopen Claude Desktop.
  3. Start a NEW conversation (existing chats won't pick up newly added tools).
  4. Ask Claude to call the Tableau tools, e.g. "check the Tableau connection".

If something doesn't connect, check the logs at:
  macOS:  ~/Library/Logs/Claude/mcp*.log
  Linux:  ~/.config/Claude/logs/mcp*.log   (path may vary by build)

See README-tableau-mcp-setup.md for a troubleshooting checklist covering the
issues hit while building this (PATH errors, dependency conflicts, wrong env
var names, and the new-chat requirement).
EOF
