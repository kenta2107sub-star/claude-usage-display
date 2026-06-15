#!/usr/bin/env python3.14
"""Claude Code usage menubar app for macOS.

Data strategy (option C):
  1. Fresh CLI cache (< 5 min old, resets_at in future) → show exact server data
  2. Otherwise → scan JSONL files for the most recent session, estimate from token counts
"""

import glob
import json
import pathlib
import time

import rumps

CACHE_PATH = pathlib.Path.home() / ".claude" / "claude_usage_cache.json"
PROJECTS_DIR = pathlib.Path.home() / ".claude" / "projects"
REFRESH_INTERVAL = 30  # seconds
CLI_CACHE_TTL = 300    # 5 min: if CLI cache is older than this, fall back to JSONL
FIVE_HOURS = 5 * 3600

# Max context window used as denominator for JSONL-based estimate.
# Claude Sonnet 4 / Opus 4 = 200K tokens.
CONTEXT_WINDOW = 200_000


# ---------------------------------------------------------------------------
# CLI cache (accurate, server-side)
# ---------------------------------------------------------------------------

def load_cli_cache():
    try:
        data = json.loads(CACHE_PATH.read_text())
        updated_at = data.get("updated_at", 0)
        resets_at = data.get("resets_at") or 0
        now = time.time()
        if now - updated_at <= CLI_CACHE_TTL and resets_at > now:
            return data
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# JSONL-based estimate (Desktop / stale cache fallback)
# ---------------------------------------------------------------------------

def estimate_from_jsonl():
    """Scan the most recent active session and return approximate usage data."""
    now = time.time()
    window_start = now - FIVE_HOURS

    best_ts = 0
    best_input = 0
    best_first_ts = None

    for jsonl_path in glob.glob(str(PROJECTS_DIR / "**" / "*.jsonl"), recursive=True):
        try:
            _scan_jsonl(jsonl_path, window_start, now,
                        result_holder := [0, 0, None])
            last_ts, last_input, first_ts = result_holder
            if last_ts > best_ts:
                best_ts = last_ts
                best_input = last_input
                best_first_ts = first_ts
        except Exception:
            continue

    if best_ts == 0:
        return None

    pct = min(round(best_input / CONTEXT_WINDOW * 100), 100)
    resets_at = (best_first_ts + FIVE_HOURS) if best_first_ts else None

    return {
        "used_percentage": pct,
        "resets_at": resets_at,
        "updated_at": best_ts,
        "estimated": True,
    }


def _scan_jsonl(path, window_start, now, result_holder):
    last_ts = 0
    last_input = 0
    first_ts = None

    with open(path, encoding="utf-8") as f:
        for raw in f:
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if entry.get("type") != "assistant":
                continue

            ts_str = entry.get("timestamp", "")
            if not ts_str:
                continue
            ts = _parse_ts(ts_str)
            if ts is None or ts < window_start or ts > now:
                continue

            usage = entry.get("message", {}).get("usage", {})
            tokens = (
                usage.get("input_tokens", 0)
                + usage.get("cache_read_input_tokens", 0)
                + usage.get("cache_creation_input_tokens", 0)
            )
            if ts > last_ts:
                last_ts = ts
                last_input = tokens

            if first_ts is None or ts < first_ts:
                first_ts = ts

    result_holder[0] = last_ts
    result_holder[1] = last_input
    result_holder[2] = first_ts


def _parse_ts(ts_str):
    try:
        from datetime import datetime, timezone
        dt = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        return dt.timestamp()
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Unified data loader
# ---------------------------------------------------------------------------

def load_data():
    data = load_cli_cache()
    if data is not None:
        return data
    return estimate_from_jsonl()


# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------

def _remaining_str(resets_at):
    now = time.time()
    if not resets_at or now >= resets_at:
        return None
    secs = int(resets_at - now)
    h, m = secs // 3600, (secs % 3600) // 60
    return f"{h}h{m:02d}m" if h > 0 else f"{m}m"


def build_title(data):
    if data is None:
        return "📊 ?"

    pct = data.get("used_percentage", 0)
    rem = _remaining_str(data.get("resets_at"))
    est = data.get("estimated", False)

    prefix = "~" if est else ""
    if rem:
        return f"📊 {prefix}{pct}% ⏱{rem}"
    return f"📊 {prefix}{pct}%"


def build_detail(data):
    if data is None:
        return "データなし（Claude Code を起動してください）"

    now = time.time()
    pct = data.get("used_percentage", "?")
    resets_at = data.get("resets_at")
    updated_at = data.get("updated_at", 0)
    est = data.get("estimated", False)

    source = "推定(JSONL)" if est else "正確(CLI)"
    lines = [f"使用量: {pct}% [{source}]"]

    if resets_at:
        if now < resets_at:
            secs = int(resets_at - now)
            h, m = secs // 3600, (secs % 3600) // 60
            lines.append(f"リセットまで: {h}h{m:02d}m")
        else:
            lines.append("リセット済み")

    age = int(now - updated_at)
    lines.append(f"最終更新: {age}秒前")
    return " | ".join(lines)


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

class ClaudeUsageApp(rumps.App):
    def __init__(self):
        super().__init__("📊 ?", quit_button=None)
        self.menu = [
            rumps.MenuItem("詳細"),
            rumps.separator,
            rumps.MenuItem("終了", callback=rumps.quit_application),
        ]
        self._update()

    def _update(self):
        data = load_data()
        self.title = build_title(data)
        self.menu["詳細"].title = build_detail(data)

    @rumps.timer(REFRESH_INTERVAL)
    def refresh(self, _):
        self._update()


if __name__ == "__main__":
    ClaudeUsageApp().run()
