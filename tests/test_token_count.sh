#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

# テスト用の一時キャッシュファイル（本番キャッシュを汚染しない）
TMP_CACHE=$(mktemp)
export CLAUDE_USAGE_CACHE="$TMP_CACHE"
trap "rm -f '$TMP_CACHE'" EXIT

check() {
    local desc="$1" result="$2" expected="$3"
    if echo "$result" | grep -q "$expected"; then
        echo "PASS: $desc = $result"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc — expected '$expected', got: $result"
        FAIL=$((FAIL + 1))
    fi
}

# テスト1: 通常ケース（resets_at が未来）
result=$(echo '{"rate_limits":{"five_hour":{"used_percentage":28,"resets_at":9999999999}}}' \
    | bash "$ROOT_DIR/claude_usage.sh")
check "通常ケース 28%" "$result" "📊 28%"

# テスト2: resets_at が過去 → used_pct が 0 に補正される
result=$(echo '{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":1}}}' \
    | bash "$ROOT_DIR/claude_usage.sh")
check "リセット済み → 0%" "$result" "📊 0%"

# テスト3: used_percentage が 0%
result=$(echo '{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":9999999999}}}' \
    | bash "$ROOT_DIR/claude_usage.sh")
check "0% ケース" "$result" "📊 0%"

# テスト4: 不正な JSON → 出力なし（終了コード 0）
result=$(echo 'invalid json' | bash "$ROOT_DIR/claude_usage.sh")
if [ -z "$result" ]; then
    echo "PASS: 不正JSON → 出力なし"
    PASS=$((PASS + 1))
else
    echo "FAIL: 不正JSON → 予期せぬ出力: $result"
    FAIL=$((FAIL + 1))
fi

# テスト5: rate_limits キーなし → 出力なし
result=$(echo '{}' | bash "$ROOT_DIR/claude_usage.sh")
if [ -z "$result" ]; then
    echo "PASS: rate_limits なし → 出力なし"
    PASS=$((PASS + 1))
else
    echo "FAIL: rate_limits なし → 予期せぬ出力: $result"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
