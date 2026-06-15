#!/usr/bin/env bash
# ~/.claude/settings.json の statusline キーにclaude_usage.shを登録する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/claude_usage.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"

if [ ! -f "$SCRIPT_PATH" ]; then
    echo "エラー: $SCRIPT_PATH が見つかりません"
    exit 1
fi

if [ ! -f "$SETTINGS_FILE" ]; then
    printf '{}' > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
fi

# 既存のsettings.jsonにstatuslineキーをマージ
python3 - "$SETTINGS_FILE" "$SCRIPT_PATH" <<'PYEOF'
import json, sys

settings_path = sys.argv[1]
script_path = sys.argv[2]

with open(settings_path) as f:
    settings = json.load(f)

settings["statusLine"] = {"type": "command", "command": script_path, "refreshInterval": 30}

import os, pathlib
tmp = pathlib.Path(settings_path).with_suffix(".tmp")
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, settings_path)

print(f"登録完了: {settings_path} に statusLine = {script_path} を設定しました")
PYEOF

# LaunchAgent でメニューバーアプリを自動起動登録
MENUBAR_SCRIPT="$SCRIPT_DIR/menubar_app.py"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.claude-usage.menubar.plist"
PYTHON_BIN="$(which python3 2>/dev/null)"

if [ -f "$MENUBAR_SCRIPT" ] && [ -n "$PYTHON_BIN" ]; then
    mkdir -p "$LAUNCH_AGENTS_DIR"
    cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude-usage.menubar</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON_BIN</string>
        <string>$MENUBAR_SCRIPT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/.claude/menubar_app.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.claude/menubar_app.log</string>
</dict>
</plist>
PLIST

    # 既存のエージェントを停止してから登録（bootstrap/bootout が現行API）
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
    echo "メニューバーアプリ登録完了: ログイン時に自動起動します"
else
    echo "警告: python3 または menubar_app.py が見つからないためメニューバーアプリをスキップしました"
fi

# AppleScriptアプリをコンパイルしてログイン項目に登録
CLAUDE_BIN="$HOME/.local/bin/claude"
APP_PATH="$HOME/Applications/ClaudeUsageCLI.app"

mkdir -p "$HOME/Applications"
osacompile -o "$APP_PATH" - <<APPLESCRIPT
-- ログイン後のセッション復元を待つ
delay 5

tell application "Terminal"
    activate
    -- 既存ウィンドウがあればそこで起動、なければ新規ウィンドウ
    if (count of windows) > 0 then
        do script "cd '$SCRIPT_DIR' && $CLAUDE_BIN" in front window
    else
        do script "cd '$SCRIPT_DIR' && $CLAUDE_BIN"
    end if
end tell
APPLESCRIPT

# 既存のログイン項目を削除してから再追加
osascript -e 'tell application "System Events" to delete (every login item whose name is "ClaudeUsageCLI")' 2>/dev/null || true
osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APP_PATH\", hidden:false}"
echo "Claude CLI自動起動登録完了: 次回ログイン時にTerminalが自動で開きます（初回のみAutomation権限の確認あり）"
