#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_SCRIPT="$ROOT_DIR/install.sh"

# テスト用の一時ディレクトリを使う
TMP_DIR=$(mktemp -d)
TMP_CLAUDE_HOME="$TMP_DIR/.claude"
mkdir -p "$TMP_CLAUDE_HOME"
echo "{}" > "$TMP_CLAUDE_HOME/settings.json"

# HOME を一時的に差し替えてinstall.shを実行
HOME="$TMP_DIR" bash "$INSTALL_SCRIPT"

# settings.jsonにstatuslineが登録されているか確認
result=$(python3 -c "
import json
with open('$TMP_CLAUDE_HOME/settings.json') as f:
    d = json.load(f)
v = d.get('statusLine', '')
print(v.get('command', '') if isinstance(v, dict) else v)
")

if echo "$result" | grep -q "claude_usage.sh"; then
    echo "PASS: statusline registered = $result"
else
    echo "FAIL: statusline not found in settings.json, got: $result"
    rm -rf "$TMP_DIR"
    exit 1
fi

rm -rf "$TMP_DIR"
