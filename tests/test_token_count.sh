#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURE="$SCRIPT_DIR/fixtures/sample_session.jsonl"

# claude_usage.sh の parse_jsonl 関数をsourceして直接テスト
source "$ROOT_DIR/claude_usage.sh"

result=$(parse_jsonl "$FIXTURE")

# 期待: 最後のメッセージの入力トークン合計 (50+0+6000=6050 → 6.0K/200K)
if echo "$result" | grep -q "6.0K/200K"; then
    echo "PASS: output contains expected token count: $result"
else
    echo "FAIL: expected output to contain '6.0K/200K', got: $result"
    exit 1
fi
