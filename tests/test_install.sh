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
mkdir -p "$TMP_CLAUDE_HOME"
mkdir -p "$TMP_LAUNCH_AGENTS"
echo "{}" > "$TMP_CLAUDE_HOME/settings.json"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

PASS=0
FAIL=0

run_install() {
    HOME="$TMP_DIR" bash -c '
        osacompile() { return 0; }
        osascript() { return 0; }
        launchctl() { return 0; }
        export -f osacompile osascript launchctl
        bash '"$INSTALL_SCRIPT"'
    ' 2>/dev/null
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

if echo "$result" | grep -q "claude_usage.sh"; then
    echo "PASS: statusLine registered = $result"
    PASS=$((PASS + 1))
else
    echo "FAIL: statusLine not found in settings.json, got: $result"
    FAIL=$((FAIL + 1))
fi

# テスト2: メニューバー用 plist が生成されているか
MENUBAR_PLIST="$TMP_LAUNCH_AGENTS/com.claude-usage.menubar.plist"
if [ -f "$MENUBAR_PLIST" ]; then
    echo "PASS: menubar plist generated"
    PASS=$((PASS + 1))
else
    echo "FAIL: menubar plist not found at $MENUBAR_PLIST"
    FAIL=$((FAIL + 1))
fi

# テスト3: ポーラー用 plist が生成されているか
POLLER_PLIST="$TMP_LAUNCH_AGENTS/com.claude-usage.rate-limit-poller.plist"
if [ -f "$POLLER_PLIST" ]; then
    echo "PASS: poller plist generated"
    PASS=$((PASS + 1))
else
    echo "FAIL: poller plist not found at $POLLER_PLIST"
    FAIL=$((FAIL + 1))
fi

# テスト4: startup-poll 用 plist が生成されているか
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
