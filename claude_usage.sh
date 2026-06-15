#!/usr/bin/env bash
# Claude Codeステータスライン用：トークン使用量表示スクリプト

TMPFILE=$(mktemp)
trap "rm -f '$TMPFILE'" EXIT
cat > "$TMPFILE"

python3 - "$TMPFILE" <<'PYEOF'
import json, sys, time, os, pathlib

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except (json.JSONDecodeError, ValueError, OSError):
    sys.exit(0)

five_hour = data.get("rate_limits", {}).get("five_hour", {})
used_pct = five_hour.get("used_percentage")
resets_at = five_hour.get("resets_at")

if used_pct is None:
    sys.exit(0)

now_ts = time.time()

# リセット時刻を過ぎていたら0%に補正
if resets_at and now_ts >= resets_at:
    used_pct = 0

pct = round(used_pct)
parts = [f"📊 {pct}%"]

remaining_secs = 0
if resets_at and now_ts < resets_at:
    remaining_secs = int(resets_at - now_ts)
    h = remaining_secs // 3600
    m = (remaining_secs % 3600) // 60
    if h > 0:
        parts.append(f"⏱ {h}h{m:02d}m でリセット")
    else:
        parts.append(f"⏱ {m}m でリセット")

# メニューバーアプリ用キャッシュをアトミックに書き出す
cache_path = pathlib.Path.home() / ".claude" / "claude_usage_cache.json"
cache = {
    "used_percentage": pct,
    "resets_at": resets_at,
    "remaining_secs": remaining_secs,
    "updated_at": now_ts,
}
try:
    tmp = cache_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(cache))
    os.replace(tmp, cache_path)
except Exception:
    pass

print(" ".join(parts))
PYEOF
