#!/usr/bin/env bash
# ログイン時にTerminalでClaude CLIを起動する（未起動時のみ）

CLAUDE_BIN="$HOME/.local/bin/claude"
TRUSTED_DIR="$(cd "$(dirname "$0")" && pwd)"

# ログイン直後はmacOSのセッション復元が終わるまで待つ
sleep 5

osascript <<APPLESCRIPT
tell application "Terminal"
    activate
    -- 既存ウィンドウがあればそこでclaudeを起動、なければ新規ウィンドウ
    if (count of windows) > 0 then
        do script "cd \"$TRUSTED_DIR\" && $CLAUDE_BIN" in front window
    else
        do script "cd \"$TRUSTED_DIR\" && $CLAUDE_BIN"
    end if
end tell
APPLESCRIPT
