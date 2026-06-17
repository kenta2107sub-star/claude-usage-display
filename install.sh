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

# ── Python3 を探す ──────────────────────────────────────────────────────────
# LaunchAgentのPATHは /usr/bin:/bin のみ。python3 を絶対パスで確定させる。
# 1) plist生成・ポーラー用（pty のみ必要。macOS標準 python3 で可）
PLIST_PYTHON=""
for candidate in /usr/local/bin/python3 /opt/homebrew/bin/python3 /usr/bin/python3; do
    if [ -x "$candidate" ] && "$candidate" -c "import pty" 2>/dev/null; then
        PLIST_PYTHON="$candidate"
        break
    fi
done
if [ -z "$PLIST_PYTHON" ]; then
    echo "エラー: python3 が見つかりません"
    exit 1
fi

# 2) メニューバーアプリ用（rumps が必要）
PYTHON_BIN=""
_which_python=$(command -v python3 2>/dev/null || true)
_python_candidates=(/usr/local/bin/python3 /opt/homebrew/bin/python3)
[ -n "$_which_python" ] && _python_candidates+=("$_which_python")
for candidate in "${_python_candidates[@]}"; do
    if [ -x "$candidate" ] && "$candidate" -c "import rumps" 2>/dev/null; then
        PYTHON_BIN="$candidate"
        break
    fi
done

# ── スクリプトを ~/.claude/ にコピー ─────────────────────────────────────────
# TCC制限：LaunchAgentはDesktop等へのアクセスが制限されるため ~/.claude/ を使う
POLLER_INSTALLED="$CLAUDE_DIR/rate_limit_poller.sh"
MENUBAR_INSTALLED="$CLAUDE_DIR/menubar_app.py"
USAGE_INSTALLED="$CLAUDE_DIR/claude_usage.sh"
cp "$SCRIPT_DIR/rate_limit_poller.sh" "$POLLER_INSTALLED"
cp "$SCRIPT_DIR/menubar_app.py" "$MENUBAR_INSTALLED"
cp "$SCRIPT_DIR/claude_usage.sh" "$USAGE_INSTALLED"
chmod 755 "$POLLER_INSTALLED" "$USAGE_INSTALLED"

# コピーしたポーラーの PYTHON3_BIN を絶対パスに書き換える
# （LaunchAgent環境では PATH が短く python3 が見つからないため）
sed -i '' "s|PYTHON3_BIN=\"\${PYTHON3_BIN:-python3}\"|PYTHON3_BIN=\"${PLIST_PYTHON}\"|" "$POLLER_INSTALLED"
echo "スクリプトを $CLAUDE_DIR にコピーしました（python3: $PLIST_PYTHON）"

# ── settings.json に statusLine を登録 ────────────────────────────────────
# statusLine command は ~/.claude/ のコピーを参照（TCC制限でDesktopが不可のため）
"$PLIST_PYTHON" - "$SETTINGS_FILE" "$USAGE_INSTALLED" <<'PYEOF'
import json, sys, os, pathlib

settings_path = sys.argv[1]
script_path = sys.argv[2]

with open(settings_path) as f:
    settings = json.load(f)

settings["statusLine"] = {"type": "command", "command": script_path, "refreshInterval": 30}

tmp = pathlib.Path(settings_path).with_suffix(".tmp")
with open(tmp, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, settings_path)

print(f"登録完了: {settings_path} に statusLine = {script_path} を設定しました")
PYEOF

# ── メニューバーアプリ LaunchAgent ────────────────────────────────────────
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.claude-usage.menubar.plist"
if [ -n "$PYTHON_BIN" ]; then
    "$PLIST_PYTHON" - "$PLIST_PATH" "$PYTHON_BIN" "$MENUBAR_INSTALLED" "$HOME" <<'PYEOF'
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
    echo "警告: rumps がインストールされた python3 が見つからないためメニューバーアプリをスキップしました"
fi

# 古いログイン項目・LaunchAgent があれば削除
osascript -e 'tell application "System Events" to delete (every login item whose name is "ClaudeUsageCLI")' 2>/dev/null || true
OLD_CLI_PLIST="$LAUNCH_AGENTS_DIR/com.claude-usage.cli-terminal.plist"
launchctl bootout "gui/$(id -u)" "$OLD_CLI_PLIST" 2>/dev/null || true
rm -f "$OLD_CLI_PLIST"

# ── startup-poll LaunchAgent（ログイン時1回・FORCE_POLL=1）─────────────────
STARTUP_PLIST="$LAUNCH_AGENTS_DIR/com.claude-usage.startup-poll.plist"
"$PLIST_PYTHON" - "$STARTUP_PLIST" "$POLLER_INSTALLED" "$HOME" <<'PYEOF'
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

# ── rate-limit-poller LaunchAgent（15分ごと）─────────────────────────────
POLLER_PLIST="$LAUNCH_AGENTS_DIR/com.claude-usage.rate-limit-poller.plist"
"$PLIST_PYTHON" - "$POLLER_PLIST" "$POLLER_INSTALLED" "$HOME" <<'PYEOF'
import sys, plistlib, pathlib
plist_path, poller_script, home = sys.argv[1], sys.argv[2], sys.argv[3]
data = {
    "Label": "com.claude-usage.rate-limit-poller",
    "ProgramArguments": ["/bin/bash", poller_script],
    "StartInterval": 900,
    "WatchPaths": [f"{home}/Library/Application Support/Claude/buddy-tokens.json"],
    "ThrottleInterval": 60,
    "StandardOutPath": f"{home}/.claude/rate_limit_poller.log",
    "StandardErrorPath": f"{home}/.claude/rate_limit_poller.log",
}
pathlib.Path(plist_path).write_bytes(plistlib.dumps(data))
PYEOF
launchctl bootout "gui/$(id -u)" "$POLLER_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$POLLER_PLIST"
echo "レート制限ポーリング登録完了: 15分ごとにバックグラウンドで更新します"
