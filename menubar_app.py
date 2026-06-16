#!/usr/bin/env python3
"""Claude Code usage menubar app for macOS.

Data strategy:
  - Fresh CLI cache (< 5 min, resets_at in future): show exact server data
  - Stale CLI cache: show last known value with "X時間前" label
  - No cache at all: show "?"
"""

import json
import pathlib
import time

import rumps

CACHE_PATH = pathlib.Path.home() / ".claude" / "claude_usage_cache.json"
REFRESH_INTERVAL = 30   # seconds
CLI_CACHE_TTL = 300     # 5 min: within this window, treat as "fresh"


def load_cache():
    try:
        return json.loads(CACHE_PATH.read_text())
    except Exception:
        return None


def _remaining_str(resets_at):
    if not resets_at:
        return None
    secs = int(resets_at - time.time())
    if secs <= 0:
        return None
    h, m = secs // 3600, (secs % 3600) // 60
    return f"{h}h{m:02d}m" if h > 0 else f"{m}m"


def _age_str(updated_at):
    if not updated_at:
        return "不明"
    secs = int(time.time() - updated_at)
    if secs < 60:
        return f"{secs}秒前"
    m = secs // 60
    if m < 60:
        return f"{m}分前"
    h = m // 60
    return f"{h}時間前"


def build_title(data):
    if data is None:
        return "📊 ?"

    pct = data.get("used_percentage", 0)
    resets_at = data.get("resets_at")
    updated_at = data.get("updated_at") or None
    rem = _remaining_str(resets_at)
    age = _age_str(updated_at) if updated_at else "不明"

    if rem:
        return f"📊 {pct}% ({age}) ⏱{rem}"
    return f"📊 {pct}% ({age})"


def build_detail(data, fresh):
    if data is None:
        return "データなし（Claude Code CLI を一度起動してください）"

    now = time.time()
    pct = data.get("used_percentage", "?")
    resets_at = data.get("resets_at")
    updated_at = data.get("updated_at", 0)
    resets_at_polled_at = data.get("resets_at_polled_at")

    lines = [f"使用量: {pct}%"]

    if resets_at:
        if now < resets_at:
            secs = int(resets_at - now)
            h, m = secs // 3600, (secs % 3600) // 60
            lines.append(f"リセットまで: {h}h{m:02d}m")
        else:
            lines.append("リセット済み")

    if fresh:
        lines.append("使用量: 正確 (CLI)")
    else:
        lines.append(f"使用量: {_age_str(updated_at)}の値 (CLI未使用)")

    if resets_at_polled_at:
        lines.append(f"リセット時刻: {_age_str(resets_at_polled_at)}更新")

    return " | ".join(lines)


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
        data = load_cache()
        if data is not None:
            updated_at = data.get("updated_at", 0)
            resets_at = data.get("resets_at")
            now = time.time()
            fresh = (now - updated_at <= CLI_CACHE_TTL) and (resets_at is None or resets_at > now)
        else:
            fresh = False

        self.title = build_title(data)
        self.menu["詳細"].title = build_detail(data, fresh)

    @rumps.timer(REFRESH_INTERVAL)
    def refresh(self, _):
        self._update()


if __name__ == "__main__":
    ClaudeUsageApp().run()
