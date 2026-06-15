#!/usr/bin/env bash
# Claude Codeステータスライン用：トークン使用量表示スクリプト

input=$(cat)

python3 - "$input" <<'PYEOF'
import json, sys, time
from datetime import datetime, timezone

try:
    data = json.loads(sys.argv[1])
except (json.JSONDecodeError, IndexError, ValueError):
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

if resets_at and now_ts < resets_at:
    remaining = int(resets_at - now_ts)
    h = remaining // 3600
    m = (remaining % 3600) // 60
    if h > 0:
        parts.append(f"⏱ {h}h{m:02d}m でリセット")
    else:
        parts.append(f"⏱ {m}m でリセット")

print(" ".join(parts))
PYEOF
