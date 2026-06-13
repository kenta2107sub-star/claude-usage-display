#!/usr/bin/env bash
# Claude Codeステータスライン用：トークン使用量表示スクリプト

input=$(cat)

python3 - "$input" <<'PYEOF'
import json, sys
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

pct = round(used_pct)
parts = [f"📊 {pct}%"]

if resets_at:
    now = datetime.now(timezone.utc)
    reset_dt = datetime.fromtimestamp(resets_at, tz=timezone.utc)
    remaining = reset_dt - now
    total_secs = int(remaining.total_seconds())
    if total_secs > 0:
        h = total_secs // 3600
        m = (total_secs % 3600) // 60
        if h > 0:
            parts.append(f"⏱ {h}h{m:02d}m でリセット")
        else:
            parts.append(f"⏱ {m}m でリセット")

print(" ".join(parts))
PYEOF
