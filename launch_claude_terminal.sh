#!/usr/bin/env bash
# ログイン時にTerminalでClaude CLIを起動する（未起動時のみ）

CLAUDE_BIN="$HOME/.local/bin/claude"
TRUSTED_DIR="$HOME/Desktop/作業フォルダ/Claude/個人開発/claude-usage-display"

# 既にclaudeが起動していれば何もしない
if pgrep -f "$CLAUDE_BIN" > /dev/null 2>&1; then
    exit 0
fi

# ログイン直後はTerminalの復元が終わるまで少し待つ
sleep 5

osascript <<APPLESCRIPT
tell application "Terminal"
    activate
    do script "cd \"$TRUSTED_DIR\" && $CLAUDE_BIN"
end tell
APPLESCRIPT
