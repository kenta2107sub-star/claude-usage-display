#!/usr/bin/env bash
# ログイン時にTerminalでClaude CLIを起動する

CLAUDE_BIN="$HOME/.local/bin/claude"
# 既に信頼済みのディレクトリで起動することで信頼確認をスキップ
TRUSTED_DIR="$HOME/Desktop/作業フォルダ/Claude/個人開発/claude-usage-display"

osascript <<APPLESCRIPT
tell application "Terminal"
    activate
    do script "cd \"$TRUSTED_DIR\" && $CLAUDE_BIN"
end tell
APPLESCRIPT
