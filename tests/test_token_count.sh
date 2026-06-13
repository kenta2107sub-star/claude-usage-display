#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/sample_session.jsonl"

# claude_usage.sh のトークン集計ロジックを直接テスト
result=$(python3 - "$FIXTURE" <<'EOF'
import json, sys

jsonl_path = sys.argv[1]
total = 0
with open(jsonl_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") != "assistant":
            continue
        usage = entry.get("message", {}).get("usage", {})
        total += usage.get("input_tokens", 0)
        total += usage.get("cache_creation_input_tokens", 0)
        total += usage.get("cache_read_input_tokens", 0)
        total += usage.get("output_tokens", 0)
print(total)
EOF
)

expected=13500  # 100+5000+2000+200 + 50+0+6000+150
if [ "$result" -eq "$expected" ]; then
    echo "PASS: token count = $result"
else
    echo "FAIL: expected $expected, got $result"
    exit 1
fi
