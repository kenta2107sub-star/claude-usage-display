#!/usr/bin/env bash
# ~/.claude/settings.json の statusline キーにclaude_usage.shを登録する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/claude_usage.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"
CLAUDE_DIR="$HOME/.claude"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

if [ ! -f "$SCRIPT_PATH" ]; then
    echo "エラー: $SCRIPT_PATH が見つかりません"
    exit 1
fi

mkdir -p "$CLAUDE_DIR" "$LAUNCH_AGENTS_DIR"

if [ ! -f "$SETTINGS_FILE" ]; then
    printf '{}' > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
fi

# LaunchAgent から実行するスクリプトは ~/.claude/ にコピーして参照する
# （Desktop等のユーザーフォルダはTCCによりLaunchAgentからアクセス制限される場合がある）
POLLER_INSTALLED="$CLAUDE_DIR/rate_limit_poller.sh"
MENUBAR_INSTALLED="$CLAUDE_DIR/menubar_app.py"
cp "$SCRIPT_DIR/rate_limit_poller.sh" "$POLLER_INSTALLED"
cp "$SCRIPT_DIR/menubar_app.py" "$MENUBAR_INSTALLED"
chmod 755 "$POLLER_INSTALLED"

echo "スクリプトを $CLAUDE_DIR にコピーしました"

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
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.claude-usage.menubar.plist"

# rumps がインストールされている python3 を探す（Homebrew優先）
PYTHON_BIN=""
for candidate in /usr/local/bin/python3 /opt/homebrew/bin/python3 "$(which python3 2>/dev/null)"; do
    if [ -x "$candidate" ] && "$candidate" -c "import rumps" 2>/dev/null; then
        PYTHON_BIN="$candidate"
        break
    fi
done

if [ -n "$PYTHON_BIN" ]; then
    python3 - "$PLIST_PATH" "$PYTHON_BIN" "$MENUBAR_INSTALLED" "$HOME" <<'PYEOF'
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

    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
    echo "メニューバーアプリ登録完了: ログイン時に自動起動します"
else
    echo "警告: python3 が見つからないためメニューバーアプリをスキップしました"
fi

# 古いログイン項目・LaunchAgent があれば削除
osascript -e 'tell application "System Events" to delete (every login item whose name is "ClaudeUsageCLI")' 2>/dev/null || true
OLD_CLI_PLIST="$LAUNCH_AGENTS_DIR/com.claude-usage.cli-terminal.plist"
launchctl bootout "gui/$(id -u)" "$OLD_CLI_PLIST" 2>/dev/null || true
rm -f "$OLD_CLI_PLIST"

# ログイン時の初回ポール用 LaunchAgent（~/.claude/ から実行）
STARTUP_PLIST="$LAUNCH_AGENTS_DIR/com.claude-usage.startup-poll.plist"
python3 - "$STARTUP_PLIST" "$POLLER_INSTALLED" "$HOME" <<'PYEOF'
import sys, plistlib, pathlib
plist_path, poller_script, home = sys.argv[1], sys.argv[2], sys.argv[3]
data = {
    "Label": "com.claude-usage.startup-poll",
    "ProgramArguments": ["/bin/bash", poller_script],
    "EnvironmentVariables": {"FORCE_POLL": "1"},
    "RunAtLoad": True,
    "ThrottleInterval": 60,
    "StandardOutPath": f"{home}/.claude/startup_poll.log",
    "StandardErrorPath": f"{home}/.claude/startup_poll.log",
}
pathlib.Path(plist_path).write_bytes(plistlib.dumps(data))
PYEOF

launchctl bootout "gui/$(id -u)" "$STARTUP_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$STARTUP_PLIST"
echo "ログイン時初回ポール登録完了: バックグラウンドで自動更新します（Terminal不要）"

# LaunchAgent でrate_limit_poller.shを15分ごとにバックグラウンド実行（~/.claude/ から実行）
POLLER_PLIST="$LAUNCH_AGENTS_DIR/com.claude-usage.rate-limit-poller.plist"
python3 - "$POLLER_PLIST" "$POLLER_INSTALLED" "$HOME" <<'PYEOF'
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
