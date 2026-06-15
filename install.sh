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

# LaunchAgent で .command ファイルを open コマンド経由で起動
# （osascript/Automation権限不要。再起動後も権限リセットされない）
COMMAND_FILE="$SCRIPT_DIR/start_claude.command"
python3 -c "import os; os.chmod('$COMMAND_FILE', 0o755)"
CLI_PLIST="$LAUNCH_AGENTS_DIR/com.claude-usage.cli-terminal.plist"

cat > "$CLI_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude-usage.cli-terminal</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>Terminal</string>
        <string>$COMMAND_FILE</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>$HOME/.claude/cli_terminal.log</string>
</dict>
</plist>
PLIST

# 古いログイン項目（ClaudeUsageCLI.app）があれば削除
osascript -e 'tell application "System Events" to delete (every login item whose name is "ClaudeUsageCLI")' 2>/dev/null || true

launchctl bootout "gui/$(id -u)" "$CLI_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$CLI_PLIST"
echo "Claude CLI自動起動登録完了: 次回ログイン時にTerminalが自動で開きます"
