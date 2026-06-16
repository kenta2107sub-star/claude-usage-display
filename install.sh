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

# ログイン時の初回ポール用 LaunchAgent（Terminal不要・バックグラウンド直接実行）
STARTUP_PLIST="$LAUNCH_AGENTS_DIR/com.claude-usage.startup-poll.plist"
POLLER_SCRIPT_ABS="$SCRIPT_DIR/rate_limit_poller.sh"

# 古いログイン項目（ClaudeUsageCLI.app）があれば削除
osascript -e 'tell application "System Events" to delete (every login item whose name is "ClaudeUsageCLI")' 2>/dev/null || true

# 古い cli-terminal LaunchAgent があれば停止・削除
OLD_CLI_PLIST="$LAUNCH_AGENTS_DIR/com.claude-usage.cli-terminal.plist"
launchctl bootout "gui/$(id -u)" "$OLD_CLI_PLIST" 2>/dev/null || true
rm -f "$OLD_CLI_PLIST"

python3 - "$STARTUP_PLIST" "$POLLER_SCRIPT_ABS" "$HOME" <<'PYEOF'
import sys, plistlib, pathlib
plist_path, poller_script, home = sys.argv[1], sys.argv[2], sys.argv[3]
data = {
    "Label": "com.claude-usage.startup-poll",
    "ProgramArguments": ["/bin/bash", poller_script],
    "EnvironmentVariables": {"FORCE_POLL": "1"},
    "RunAtLoad": True,
    "StandardOutPath": f"{home}/.claude/startup_poll.log",
    "StandardErrorPath": f"{home}/.claude/startup_poll.log",
}
pathlib.Path(plist_path).write_bytes(plistlib.dumps(data))
PYEOF

launchctl bootout "gui/$(id -u)" "$STARTUP_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$STARTUP_PLIST"
echo "ログイン時初回ポール登録完了: バックグラウンドで自動更新します（Terminal不要）"

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
