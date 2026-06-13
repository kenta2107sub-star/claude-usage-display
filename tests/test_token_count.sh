#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# stdinからJSONを渡してテスト
result=$(echo '{"rate_limits":{"five_hour":{"used_percentage":28,"resets_at":9999999999}}}' | bash "$ROOT_DIR/claude_usage.sh")

if echo "$result" | grep -q "📊 28%"; then
    echo "PASS: output = $result"
else
    echo "FAIL: expected '📊 28%', got: $result"
    exit 1
fi
