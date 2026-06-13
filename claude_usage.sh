#!/usr/bin/env bash
# Claude Codeステータスライン用：トークン使用量表示スクリプト

set -euo pipefail

CONTEXT_WINDOW=200000
RESET_HOURS=5

# 現在の作業ディレクトリからセッションIDを特定
find_session_id() {
    local cwd
    cwd="$(pwd)"
    local sessions_dir="$HOME/.claude/sessions"

    if [ ! -d "$sessions_dir" ]; then
        return 1
    fi

    for session_file in "$sessions_dir"/*.json; do
        [ -f "$session_file" ] || continue
        local file_cwd
        file_cwd=$(python3 -c "
import json, sys
try:
    with open('$session_file') as f:
        d = json.load(f)
    print(d.get('cwd', ''))
except:
    print('')
")
        if [ "$file_cwd" = "$cwd" ]; then
            python3 -c "
import json
with open('$session_file') as f:
    d = json.load(f)
print(d.get('sessionId', ''))
"
            return 0
        fi
    done
    return 1
}

# cwdをプロジェクトパス形式（-区切り）に変換
encode_cwd() {
    echo "$1" | sed 's|/|-|g'
}

# JSOLからトークン集計とリセット時間を計算
parse_jsonl() {
    local jsonl_path="$1"
    python3 - "$jsonl_path" <<'PYEOF'
import json, sys
from datetime import datetime, timezone, timedelta

jsonl_path = sys.argv[1]
total_tokens = 0
first_ts = None

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
        total_tokens += usage.get("input_tokens", 0)
        total_tokens += usage.get("cache_creation_input_tokens", 0)
        total_tokens += usage.get("cache_read_input_tokens", 0)
        total_tokens += usage.get("output_tokens", 0)
        if first_ts is None:
            ts_str = entry.get("timestamp", "")
            if ts_str:
                try:
                    first_ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                except ValueError:
                    pass

CONTEXT_WINDOW = 200000
RESET_HOURS = 5

pct = round(total_tokens / CONTEXT_WINDOW * 100)

if total_tokens >= 1000:
    tok_display = f"{total_tokens/1000:.1f}K"
else:
    tok_display = str(total_tokens)

reset_str = ""
if first_ts:
    now = datetime.now(timezone.utc)
    reset_at = first_ts + timedelta(hours=RESET_HOURS)
    remaining = reset_at - now
    if remaining.total_seconds() > 0:
        total_secs = int(remaining.total_seconds())
        h = total_secs // 3600
        m = (total_secs % 3600) // 60
        if h > 0:
            reset_str = f"⏱ {h}h{m:02d}m でリセット"
        else:
            reset_str = f"⏱ {m}m でリセット"

parts = [f"📊 {pct}% ({tok_display}/200K)"]
if reset_str:
    parts.append(reset_str)
print(" ".join(parts))
PYEOF
}

main() {
    local session_id
    session_id=$(find_session_id 2>/dev/null) || { echo ""; exit 0; }

    [ -z "$session_id" ] && { echo ""; exit 0; }

    local cwd_encoded
    cwd_encoded=$(encode_cwd "$(pwd)")

    local jsonl_path="$HOME/.claude/projects/${cwd_encoded}/${session_id}.jsonl"

    if [ ! -f "$jsonl_path" ]; then
        echo ""
        exit 0
    fi

    parse_jsonl "$jsonl_path"
}

main
