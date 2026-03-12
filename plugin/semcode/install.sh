#!/bin/bash
# Installation script for semcode MCP server
# Supports: Claude Code, Cursor IDE, VS Code

set -eo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PLUGIN_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
SEMCODE_ROOT="$( cd "$SCRIPT_DIR/../.." && pwd )"
PLUGIN_NAME="semcode"
MARKETPLACE_NAME="semcode-local"

echo "=== Semcode MCP Server Installation ==="
echo

# -----------------------------------------------------------------------
# Locate semcode-mcp binary
# -----------------------------------------------------------------------
MCP_PATH=""
if command -v semcode-mcp &> /dev/null; then
    MCP_PATH="$(command -v semcode-mcp)"
    echo "Found semcode-mcp at: $MCP_PATH"
elif [ -f "$SEMCODE_ROOT/target/release/semcode-mcp" ]; then
    echo "Error: semcode-mcp found in target/release but not in PATH"
    echo "  export PATH=\"$SEMCODE_ROOT/target/release:\$PATH\""
    exit 1
else
    echo "Error: semcode-mcp binary not found"
    echo "  cd $SEMCODE_ROOT && cargo build --release"
    echo "  export PATH=\"$SEMCODE_ROOT/target/release:\$PATH\""
    exit 1
fi

echo

# -----------------------------------------------------------------------
# Step 1: Choose installation targets
# -----------------------------------------------------------------------
echo "Step 1: Choose installation targets"
echo
echo "  1. Claude Code only"
echo "  2. Cursor IDE only"
echo "  3. VS Code only"
echo "  4. Cursor + VS Code"
echo "  5. All (Claude Code + Cursor + VS Code)"
echo

read -p "Choice [1-5] (default: 5): " target_choice || true
target_choice="${target_choice:-5}"

INSTALL_CLAUDE=false
INSTALL_CURSOR=false
INSTALL_VSCODE=false

case $target_choice in
    1) INSTALL_CLAUDE=true ;;
    2) INSTALL_CURSOR=true ;;
    3) INSTALL_VSCODE=true ;;
    4) INSTALL_CURSOR=true; INSTALL_VSCODE=true ;;
    *) INSTALL_CLAUDE=true; INSTALL_CURSOR=true; INSTALL_VSCODE=true ;;
esac

# -----------------------------------------------------------------------
# Step 2: Git repository path (Cursor / VS Code)
# -----------------------------------------------------------------------
GIT_REPO_PATH=""

if $INSTALL_CURSOR || $INSTALL_VSCODE; then
    echo
    echo "Step 2: Git repository path"
    echo
    echo "  Cursor and VS Code need a project-level mcp.json."
    echo "  This is also where semcode-index typically creates .semcode.db."
    echo

    read -p "Git repository path (e.g. ~/linux): " user_repo || true
    user_repo="${user_repo:-}"
    user_repo="${user_repo/#\~/$HOME}"

    if [ -z "$user_repo" ]; then
        echo "No path given, skipping Cursor/VS Code setup."
        INSTALL_CURSOR=false
        INSTALL_VSCODE=false
    else
        GIT_REPO_PATH="$(realpath "$user_repo" 2>/dev/null || echo "$user_repo")"
        if [ ! -d "$GIT_REPO_PATH" ]; then
            echo "Warning: $GIT_REPO_PATH does not exist yet, proceeding anyway."
        fi
        echo "Git repo: $GIT_REPO_PATH"
    fi
fi

# Nothing left to install?
if ! $INSTALL_CLAUDE && ! $INSTALL_CURSOR && ! $INSTALL_VSCODE; then
    echo
    echo "Nothing to install."
    exit 0
fi

# -----------------------------------------------------------------------
# Step 3: Configure database location
#
# Default to the git repo path (where semcode-index -s . creates .semcode.db).
# Only ask if Cursor or VS Code is being installed (they need -d in mcp.json).
# Claude Code doesn't need this -- review_one.sh handles it at runtime.
# -----------------------------------------------------------------------
SEMCODE_DB=""

if $INSTALL_CURSOR || $INSTALL_VSCODE; then
    SEMCODE_DB="$GIT_REPO_PATH"

    echo
    echo "Step 3: Configure database location"
    echo
    echo "  Default: $SEMCODE_DB"
    if [ -d "$SEMCODE_DB/.semcode.db" ]; then
        echo "  Database exists at $SEMCODE_DB/.semcode.db"
    else
        echo "  Database not found yet -- run 'semcode-index -s $SEMCODE_DB' to create it."
    fi
    echo
    echo "  1. Use default: $SEMCODE_DB"
    echo "  2. Specify a different path"
    echo

    read -p "Choice [1-2] (default: 1): " db_choice || true
    db_choice="${db_choice:-1}"

    case $db_choice in
        2)
            read -p "Full path to database directory: " user_db || true
            user_db="${user_db:-}"
            if [ -z "$user_db" ]; then
                echo "  No path given, using default."
            else
                user_db="${user_db/#\~/$HOME}"
                SEMCODE_DB="$(realpath "$user_db" 2>/dev/null || echo "$user_db")"
            fi
            ;;
    esac

    echo "Database: $SEMCODE_DB"
    echo
fi

# -----------------------------------------------------------------------
# Write or merge an mcp.json with semcode server config.
# Uses -d and --git-repo explicitly so semcode-mcp doesn't rely on
# auto-detection from the working directory.
# If the file exists and jq is available, merge to preserve other servers.
#
#   write_mcp_json <dir>
# -----------------------------------------------------------------------
write_mcp_json() {
    local target_dir="$1"

    mkdir -p "$target_dir"
    local target_file="$target_dir/mcp.json"
    local semcode_entry
    semcode_entry=$(cat <<INNEREOF
{
  "mcpServers": {
    "semcode": {
      "command": "$MCP_PATH",
      "args": ["-d", "$SEMCODE_DB", "--git-repo", "$GIT_REPO_PATH"]
    }
  }
}
INNEREOF
)

    if [ -f "$target_file" ] && command -v jq &> /dev/null; then
        local backup
        backup="$(mktemp "$target_file.bak.XXXXXX")"
        cp "$target_file" "$backup"

        local tmp
        tmp="$(mktemp)"
        if jq --arg cmd "$MCP_PATH" \
              --arg db "$SEMCODE_DB" \
              --arg repo "$GIT_REPO_PATH" \
              '.mcpServers.semcode = {"command": $cmd, "args": ["-d", $db, "--git-repo", $repo]}' \
              "$backup" > "$tmp"; then
            mv "$tmp" "$target_file"
            echo "  Merged semcode into existing $target_file"
        else
            rm -f "$tmp"
            echo "  jq merge failed, restoring backup"
            cp "$backup" "$target_file"
        fi
        echo "  Backup: $backup"
    else
        echo "$semcode_entry" > "$target_file"
        echo "  Created $target_file"
    fi
}

# -----------------------------------------------------------------------
# Claude Code
# -----------------------------------------------------------------------
if $INSTALL_CLAUDE; then
    echo
    echo "=== Claude Code Setup ==="
    echo

    if ! command -v claude &> /dev/null; then
        echo "'claude' command not found, skipping Claude Code setup."
        echo "  Install Claude Code and re-run to enable."
    else
        echo "Found claude command"

        echo "  Adding marketplace..."
        if claude plugin marketplace add "$PLUGIN_DIR/marketplace.json" 2>/dev/null; then
            echo "  Marketplace added"
        else
            echo "  Marketplace may already be added (OK)"
        fi

        echo "  Installing plugin..."
        if claude plugin install "$PLUGIN_NAME@$MARKETPLACE_NAME" 2>/dev/null; then
            echo "  Plugin installed"
        else
            echo "  Plugin may already be installed (OK)"
        fi

        MCP_CONFIG="$SCRIPT_DIR/mcp/semcode.json"
        mkdir -p "$(dirname "$MCP_CONFIG")"

        cat > "$MCP_CONFIG" << EOF
{
  "mcpServers": {
    "semcode": {
      "command": "$MCP_PATH"
    }
  }
}
EOF
        echo "  Claude MCP config: $MCP_CONFIG"
    fi
fi

# -----------------------------------------------------------------------
# Cursor IDE
# -----------------------------------------------------------------------
if $INSTALL_CURSOR; then
    echo
    echo "=== Cursor IDE Setup ==="
    echo

    write_mcp_json "$GIT_REPO_PATH/.cursor"
fi

# -----------------------------------------------------------------------
# VS Code
# -----------------------------------------------------------------------
if $INSTALL_VSCODE; then
    echo
    echo "=== VS Code Setup ==="
    echo

    write_mcp_json "$GIT_REPO_PATH/.vscode"
fi

# -----------------------------------------------------------------------
# Tool approval (Claude Code only)
# -----------------------------------------------------------------------
if $INSTALL_CLAUDE; then
    echo
    echo "=== Tool Approval (Claude Code, Optional) ==="
    echo
    echo "Pre-approve semcode tools for a directory to skip permission prompts?"
    echo
    read -p "Directory path (or Enter to skip): " APPROVE_DIR || true
    APPROVE_DIR="${APPROVE_DIR:-}"

    if [ -n "$APPROVE_DIR" ]; then
        APPROVE_DIR="${APPROVE_DIR/#\~/$HOME}"
        APPROVE_DIR="$(realpath "$APPROVE_DIR" 2>/dev/null || echo "$APPROVE_DIR")"

        TOOLS=(
            "mcp__semcode__find_function"
            "mcp__semcode__find_type"
            "mcp__semcode__find_callers"
            "mcp__semcode__find_calls"
            "mcp__semcode__find_callchain"
            "mcp__semcode__diff_functions"
            "mcp__semcode__grep_functions"
            "mcp__semcode__vgrep_functions"
            "mcp__semcode__find_commit"
            "mcp__semcode__vcommit_similar_commits"
            "mcp__semcode__lore_search"
            "mcp__semcode__dig"
            "mcp__semcode__vlore_similar_emails"
        )

        if ! command -v jq &> /dev/null; then
            echo "jq not found, skipping tool pre-approval."
            echo "  Install jq, then run: $SCRIPT_DIR/approve-tools.sh $APPROVE_DIR"
        elif [ ! -f ~/.claude.json ]; then
            echo "~/.claude.json not found (run Claude Code once first)."
            echo "  Then run: $SCRIPT_DIR/approve-tools.sh $APPROVE_DIR"
        else
            cp ~/.claude.json ~/.claude.json.backup
            TEMP_FILE="$(mktemp)"

            if jq --arg dir "$APPROVE_DIR" \
                  --argjson tools "$(printf '%s\n' "${TOOLS[@]}" | jq -R . | jq -s .)" \
                  '.projects[$dir].allowedTools = ($tools + (.projects[$dir].allowedTools // []) | unique)' \
                  ~/.claude.json > "$TEMP_FILE"; then
                mv "$TEMP_FILE" ~/.claude.json
                echo "Pre-approved semcode tools for $APPROVE_DIR"
                echo "  Backup: ~/.claude.json.backup"
            else
                rm -f "$TEMP_FILE"
                echo "jq failed, ~/.claude.json not modified."
            fi
        fi
    else
        echo "Skipped."
    fi
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo
echo "=== Installation Complete ==="
echo
echo "Binary: $MCP_PATH"
[ -n "$SEMCODE_DB" ] && echo "Database: $SEMCODE_DB"
echo

$INSTALL_CLAUDE && echo "Claude Code: $SCRIPT_DIR/mcp/semcode.json" || true
$INSTALL_CURSOR && echo "Cursor:      $GIT_REPO_PATH/.cursor/mcp.json" || true
$INSTALL_VSCODE && echo "VS Code:     $GIT_REPO_PATH/.vscode/mcp.json" || true

echo
echo "Restart any running editors for the changes to take effect."
echo
echo "Docs: $SEMCODE_ROOT/docs/semcode-mcp.md"
