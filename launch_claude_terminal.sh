#!/usr/bin/env bash
# ログイン時にTerminalでClaude CLIを起動する

CLAUDE_BIN="$HOME/.local/bin/claude"

osascript <<APPLESCRIPT
tell application "Terminal"
    activate
    do script "$CLAUDE_BIN"
end tell
APPLESCRIPT
