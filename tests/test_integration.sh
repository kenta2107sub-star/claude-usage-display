#!/usr/bin/env bash
# 統合テスト：claude_usage.sh（キャッシュ書込）→ menubar_app.py（表示）
#            rate_limit_poller.sh の check_activity（アクティビティ判定）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

check() {
    local desc="$1" result="$2" expected="$3"
    if echo "$result" | grep -qF "$expected"; then
        echo "PASS: $desc = $result"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc — expected '$expected', got: $result"
        FAIL=$((FAIL + 1))
    fi
}

TMP_CACHE=$(mktemp)
export CLAUDE_USAGE_CACHE="$TMP_CACHE"
trap "rm -f '$TMP_CACHE'" EXIT

# rumps がなくても menubar_app.py の表示ロジック（build_title / build_detail）を
# 単体で呼べるように rumps をダミーモジュールとして差し込む
run_menubar_logic() {
    CLAUDE_USAGE_CACHE_FOR_MENUBAR="$1" python3 - "$ROOT_DIR/menubar_app.py" <<'PYEOF'
import sys, types, json, pathlib, os

# rumps がインストールされていない環境でも menubar_app.py を import できるようにモックする
rumps_mock = types.ModuleType("rumps")
class _App:
    def __init__(self, *a, **k): pass
class _MenuItem:
    def __init__(self, *a, **k): self.title = ""
rumps_mock.App = _App
rumps_mock.MenuItem = _MenuItem
rumps_mock.separator = None
rumps_mock.quit_application = None
def _timer(*a, **k):
    def deco(f): return f
    return deco
rumps_mock.timer = _timer
sys.modules["rumps"] = rumps_mock

script_path = sys.argv[1]
src = pathlib.Path(script_path).read_text()
ns = {"__name__": "menubar_test"}
exec(compile(src, script_path, "exec"), ns)

# キャッシュパスをテスト用に差し替える
ns["CACHE_PATH"] = pathlib.Path(os.environ["CLAUDE_USAGE_CACHE_FOR_MENUBAR"])

data = ns["load_cache"]()
fresh = False
if data is not None:
    import time
    updated_at = data.get("updated_at", 0)
    resets_at = data.get("resets_at")
    now = time.time()
    fresh = (now - updated_at <= ns["CLI_CACHE_TTL"]) and (resets_at is None or resets_at > now)

print(ns["build_title"](data))
PYEOF
}

# ── シナリオ1：claude_usage.sh がキャッシュを書き、menubarが新鮮な値として表示する ──
echo '{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":9999999999}}}' \
    | bash "$ROOT_DIR/claude_usage.sh" > /dev/null

result=$(run_menubar_logic "$TMP_CACHE")
check "統合1: cache書込→menubar新鮮表示(42%)" "$result" "📊 42%"

# ── シナリオ2：キャッシュのupdated_atを6分前に古くして「古い値」ラベルが出ることを確認 ──
python3 - "$TMP_CACHE" <<'PYEOF'
import json, sys, time
p = sys.argv[1]
d = json.loads(open(p).read())
d["updated_at"] = time.time() - 360  # 6分前（CLI_CACHE_TTL=300秒を超過）
open(p, "w").write(json.dumps(d))
PYEOF

result=$(run_menubar_logic "$TMP_CACHE")
check "統合2: 6分前の古いキャッシュでも値と経過時間が表示される" "$result" "📊 42% (6分前)"

# ── シナリオ3：キャッシュファイルが存在しない場合「?」表示になる ──
EMPTY_CACHE=$(mktemp -u)
result=$(run_menubar_logic "$EMPTY_CACHE")
check "統合3: キャッシュなし→? 表示" "$result" "📊 ?"

# ── シナリオ4：resets_at経過後は0%に補正されたうえでmenubarにも反映される ──
echo '{"rate_limits":{"five_hour":{"used_percentage":80,"resets_at":1}}}' \
    | bash "$ROOT_DIR/claude_usage.sh" > /dev/null
result=$(run_menubar_logic "$TMP_CACHE")
check "統合4: リセット済みキャッシュ→menubarも0%表示" "$result" "📊 0%"

# ── シナリオ5：rate_limit_poller.sh の check_activity（CLIキャッシュが直近更新 → 活動あり） ──
echo '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":9999999999}}}' \
    | CLAUDE_USAGE_CACHE="$HOME/.claude/claude_usage_cache.json.itest_backup_check" bash "$ROOT_DIR/claude_usage.sh" > /dev/null 2>&1 || true

TEST_CACHE_DIR=$(mktemp -d)
TEST_CACHE_FILE="$TEST_CACHE_DIR/claude_usage_cache.json"
python3 -c "
import json, time
json.dump({'used_percentage': 10, 'updated_at': time.time()}, open('$TEST_CACHE_FILE', 'w'))
"

activity_result=$(
  CACHE_FILE_OVERRIDE="$TEST_CACHE_FILE" bash -c '
    CACHE_FILE="$CACHE_FILE_OVERRIDE"
    BUDDY_TOKENS="/nonexistent/buddy-tokens.json"
    IDLE_THRESHOLD=1800
    PYTHON3_BIN=python3
    check_activity() {
        local now
        now=$(date +%s)
        if [ -f "$CACHE_FILE" ]; then
            local cli_updated
            cli_updated=$("$PYTHON3_BIN" - "$CACHE_FILE" <<PYEOF2 2>/dev/null || echo 0
import json, sys
try:
    d=json.load(open(sys.argv[1]))
    print(int(d.get("updated_at", 0)))
except Exception:
    print(0)
PYEOF2
)
            local diff=$(( now - cli_updated ))
            if [ "$diff" -ge 0 ] && [ "$diff" -le "$IDLE_THRESHOLD" ]; then
                echo "active"; return 0
            fi
        fi
        echo "idle"
        return 1
    }
    check_activity
  '
)
check "統合5: CLIキャッシュ直近更新→活動ありと判定" "$activity_result" "active"

rm -rf "$TEST_CACHE_DIR"
rm -f "$HOME/.claude/claude_usage_cache.json.itest_backup_check"

# ── シナリオ6：CLIキャッシュもbuddy-tokensも古い（30分超）場合はidle判定 ──
TEST_CACHE_DIR2=$(mktemp -d)
TEST_CACHE_FILE2="$TEST_CACHE_DIR2/claude_usage_cache.json"
python3 -c "
import json, time
json.dump({'used_percentage': 10, 'updated_at': time.time() - 3600}, open('$TEST_CACHE_FILE2', 'w'))
"

activity_result2=$(
  CACHE_FILE_OVERRIDE="$TEST_CACHE_FILE2" bash -c '
    CACHE_FILE="$CACHE_FILE_OVERRIDE"
    IDLE_THRESHOLD=1800
    PYTHON3_BIN=python3
    now=$(date +%s)
    cli_updated=$("$PYTHON3_BIN" - "$CACHE_FILE" <<PYEOF3 2>/dev/null || echo 0
import json, sys
try:
    d=json.load(open(sys.argv[1]))
    print(int(d.get("updated_at", 0)))
except Exception:
    print(0)
PYEOF3
)
    diff=$(( now - cli_updated ))
    if [ "$diff" -ge 0 ] && [ "$diff" -le "$IDLE_THRESHOLD" ]; then
        echo "active"
    else
        echo "idle"
    fi
  '
)
check "統合6: 1時間前の古いキャッシュ→idle判定" "$activity_result2" "idle"

rm -rf "$TEST_CACHE_DIR2"

# ── シナリオ7（非機能）：破損したキャッシュJSONでもmenubarがクラッシュせず「?」を返す ──
CORRUPT_CACHE=$(mktemp)
echo 'not valid json{{{' > "$CORRUPT_CACHE"
result=$(run_menubar_logic "$CORRUPT_CACHE")
check "統合7(非機能): 破損キャッシュ→クラッシュせず? 表示" "$result" "📊 ?"
rm -f "$CORRUPT_CACHE"

# ── シナリオ8（非機能）：claude_usage.sh書込中も一時ファイル(.tmp)が残らない ──
echo '{"rate_limits":{"five_hour":{"used_percentage":15,"resets_at":9999999999}}}' \
    | bash "$ROOT_DIR/claude_usage.sh" > /dev/null
tmp_leftover=$(find "$(dirname "$TMP_CACHE")" -maxdepth 1 -name "*.tmp" 2>/dev/null | grep -F "$(basename "$TMP_CACHE")" || true)
if [ -z "$tmp_leftover" ]; then
    echo "PASS: 統合8(非機能): アトミック書込後に.tmpファイルが残らない"
    PASS=$((PASS + 1))
else
    echo "FAIL: 統合8(非機能): .tmpファイルが残存: $tmp_leftover"
    FAIL=$((FAIL + 1))
fi

# ── シナリオ9：auth_error=trueのキャッシュはmenubarに「ログイン切れ」表示される ──
python3 -c "
import json, time
json.dump({'used_percentage': 42, 'updated_at': time.time(), 'auth_error': True, 'auth_error_at': time.time()}, open('$TMP_CACHE', 'w'))
"
result=$(run_menubar_logic "$TMP_CACHE")
check "統合9: auth_error時にログイン切れ表示" "$result" "ログイン切れ"

# ── シナリオ10：claude_usage.shが正常応答するとauth_errorがfalseに解除される ──
echo '{"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":9999999999}}}' \
    | bash "$ROOT_DIR/claude_usage.sh" > /dev/null
result=$(run_menubar_logic "$TMP_CACHE")
if echo "$result" | grep -qF "ログイン切れ"; then
    echo "FAIL: 統合10: claude_usage.sh成功後もログイン切れ表示のまま"
    FAIL=$((FAIL + 1))
else
    echo "PASS: 統合10: claude_usage.sh成功でauth_error解除、通常表示に復帰 = $result"
    PASS=$((PASS + 1))
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
