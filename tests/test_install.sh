#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_SCRIPT="$ROOT_DIR/install.sh"

# python3 が存在するか確認
if ! command -v python3 &>/dev/null; then
    echo "SKIP: python3 not found"
    exit 0
fi

# テスト用の一時ディレクトリを使う
TMP_DIR=$(mktemp -d)
TMP_CLAUDE_HOME="$TMP_DIR/.claude"
TMP_LAUNCH_AGENTS="$TMP_DIR/Library/LaunchAgents"
TMP_BIN="$TMP_DIR/bin"
mkdir -p "$TMP_CLAUDE_HOME" "$TMP_LAUNCH_AGENTS" "$TMP_BIN"
echo "{}" > "$TMP_CLAUDE_HOME/settings.json"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

PASS=0
FAIL=0

# launchctl/osascript をファイルモックとして配置（macOS bash では export -f が不安定なため）
for cmd in launchctl osascript; do
    printf '#!/bin/bash\nexit 0\n' > "$TMP_BIN/$cmd"
    chmod +x "$TMP_BIN/$cmd"
done

run_install() {
    HOME="$TMP_DIR" PATH="$TMP_BIN:$PATH" bash "$INSTALL_SCRIPT" 2>/dev/null
}

run_install

# テスト1: settings.json に statusLine が登録されているか
result=$(python3 -c "
import json
with open('$TMP_CLAUDE_HOME/settings.json') as f:
    d = json.load(f)
v = d.get('statusLine', '')
print(v.get('command', '') if isinstance(v, dict) else v)
")

if echo "$result" | grep -qF "claude_usage.sh"; then
    echo "PASS: statusLine registered = $result"
    PASS=$((PASS + 1))
else
    echo "FAIL: statusLine not found in settings.json, got: $result"
    FAIL=$((FAIL + 1))
fi

# テスト2: メニューバー用 plist が生成されているか（rumps がある場合のみ）
MENUBAR_PLIST="$TMP_LAUNCH_AGENTS/com.claude-usage.menubar.plist"
if python3 -c "import rumps" 2>/dev/null; then
    if [ -f "$MENUBAR_PLIST" ]; then
        echo "PASS: menubar plist generated"
        PASS=$((PASS + 1))
    else
        echo "FAIL: menubar plist not found at $MENUBAR_PLIST"
        FAIL=$((FAIL + 1))
    fi
else
    echo "SKIP: menubar plist (rumps not installed)"
fi

# テスト3: スクリプトが ~/.claude/ にコピーされているか
if [ -f "$TMP_DIR/.claude/rate_limit_poller.sh" ] && [ -f "$TMP_DIR/.claude/menubar_app.py" ]; then
    echo "PASS: scripts copied to ~/.claude/"
    PASS=$((PASS + 1))
else
    echo "FAIL: scripts not copied to ~/.claude/"
    FAIL=$((FAIL + 1))
fi

# テスト4: ポーラー用 plist が生成されているか
POLLER_PLIST="$TMP_LAUNCH_AGENTS/com.claude-usage.rate-limit-poller.plist"
if [ -f "$POLLER_PLIST" ]; then
    echo "PASS: poller plist generated"
    PASS=$((PASS + 1))
else
    echo "FAIL: poller plist not found at $POLLER_PLIST"
    FAIL=$((FAIL + 1))
fi

# テスト5: startup-poll 用 plist が生成されているか
STARTUP_PLIST="$TMP_LAUNCH_AGENTS/com.claude-usage.startup-poll.plist"
if [ -f "$STARTUP_PLIST" ]; then
    echo "PASS: startup-poll plist generated"
    PASS=$((PASS + 1))
else
    echo "FAIL: startup-poll plist not found at $STARTUP_PLIST"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
