#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURE="$SCRIPT_DIR/fixtures/sample_session.jsonl"

# claude_usage.sh の parse_jsonl 関数をsourceして直接テスト
source "$ROOT_DIR/claude_usage.sh"

result=$(parse_jsonl "$FIXTURE")

# 期待: "📊 7% (13.5K/200K)" を含む出力
if echo "$result" | grep -q "13.5K/200K"; then
    echo "PASS: output contains expected token count: $result"
else
    echo "FAIL: expected output to contain '13.5K/200K', got: $result"
    exit 1
fi
