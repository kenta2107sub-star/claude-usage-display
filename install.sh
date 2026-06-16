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
    # C-3修正: パスに特殊文字が含まれてもXMLが壊れないようPythonでplistを生成する
    python3 - "$PLIST_PATH" "$PYTHON_BIN" "$MENUBAR_SCRIPT" "$HOME" <<'PYEOF'
import sys, plistlib, pathlib
plist_path, python_bin, menubar_script, home = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = {
    "Label": "com.claude-usage.menubar",
    "ProgramArguments": [python_bin, menubar_script],
    "RunAtLoad": True,
    "KeepAlive": True,
    "StandardOutPath": f"{home}/.claude/menubar_app.log",
    "StandardErrorPath": f"{home}/.claude/menubar_app.log",
}
pathlib.Path(plist_path).write_bytes(plistlib.dumps(data))
PYEOF

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
python3 - "$COMMAND_FILE" <<'PYEOF'
import sys, os
os.chmod(sys.argv[1], 0o755)
PYEOF
CLI_PLIST="$LAUNCH_AGENTS_DIR/com.claude-usage.cli-terminal.plist"

# C-3修正: PythonでplistをXMLエスケープ安全に生成する
python3 - "$CLI_PLIST" "$COMMAND_FILE" "$HOME" <<'PYEOF'
import sys, plistlib, pathlib
plist_path, command_file, home = sys.argv[1], sys.argv[2], sys.argv[3]
data = {
    "Label": "com.claude-usage.cli-terminal",
    "ProgramArguments": ["/usr/bin/open", "-a", "Terminal", command_file],
    "RunAtLoad": True,
    "StandardErrorPath": f"{home}/.claude/cli_terminal.log",
}
pathlib.Path(plist_path).write_bytes(plistlib.dumps(data))
PYEOF

# 古いログイン項目（ClaudeUsageCLI.app）があれば削除
osascript -e 'tell application "System Events" to delete (every login item whose name is "ClaudeUsageCLI")' 2>/dev/null || true

launchctl bootout "gui/$(id -u)" "$CLI_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$CLI_PLIST"
echo "Claude CLI自動起動登録完了: 次回ログイン時にTerminalが自動で開きます"

# LaunchAgent でrate_limit_poller.shを15分ごとにバックグラウンド実行（ターミナル不要）
POLLER_SCRIPT="$SCRIPT_DIR/rate_limit_poller.sh"
POLLER_PLIST="$LAUNCH_AGENTS_DIR/com.claude-usage.rate-limit-poller.plist"
python3 - "$POLLER_SCRIPT" <<'PYEOF'
import sys, os
os.chmod(sys.argv[1], 0o755)
PYEOF

# C-3修正: PythonでplistをXMLエスケープ安全に生成する
# I-1修正: ThrottleInterval を追加してクラッシュ時の無限即時再起動を防ぐ
python3 - "$POLLER_PLIST" "$POLLER_SCRIPT" "$HOME" <<'PYEOF'
import sys, plistlib, pathlib
plist_path, poller_script, home = sys.argv[1], sys.argv[2], sys.argv[3]
data = {
    "Label": "com.claude-usage.rate-limit-poller",
    "ProgramArguments": ["/bin/bash", poller_script],
    "StartInterval": 900,
    "ThrottleInterval": 60,
    "StandardOutPath": f"{home}/.claude/rate_limit_poller.log",
    "StandardErrorPath": f"{home}/.claude/rate_limit_poller.log",
}
pathlib.Path(plist_path).write_bytes(plistlib.dumps(data))
PYEOF

launchctl bootout "gui/$(id -u)" "$POLLER_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$POLLER_PLIST"
echo "レート制限ポーリング登録完了: 15分ごとにバックグラウンドで更新します"
