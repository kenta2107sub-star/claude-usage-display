#!/usr/bin/env python3.14
"""Claude Code usage menubar app for macOS."""

import json
import time
import pathlib
import rumps

CACHE_PATH = pathlib.Path.home() / ".claude" / "claude_usage_cache.json"
REFRESH_INTERVAL = 30  # seconds
STALE_THRESHOLD = 300  # 5 minutes — if cache is older than this, show "?"


def load_cache():
    try:
        data = json.loads(CACHE_PATH.read_text())
        return data
    except Exception:
        return None


def build_title(data):
    if data is None:
        return "📊 ?"

    updated_at = data.get("updated_at", 0)
    if time.time() - updated_at > STALE_THRESHOLD:
        return "📊 ?"

    pct = data.get("used_percentage", 0)
    resets_at = data.get("resets_at")
    now = time.time()

    if resets_at and now >= resets_at:
        return "📊 0%"

    remaining = int(resets_at - now) if resets_at and resets_at > now else 0
    h = remaining // 3600
    m = (remaining % 3600) // 60

    if remaining > 0:
        if h > 0:
            return f"📊 {pct}% ⏱{h}h{m:02d}m"
        else:
            return f"📊 {pct}% ⏱{m}m"
    return f"📊 {pct}%"


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
        self.title = build_title(data)

        detail = self.menu["詳細"]
        if data is None:
            detail.title = "データなし（Claude Code CLIを起動してください）"
            return

        pct = data.get("used_percentage", "?")
        resets_at = data.get("resets_at")
        updated_at = data.get("updated_at", 0)
        now = time.time()

        lines = [f"使用量: {pct}%"]
        if resets_at:
            if now < resets_at:
                remaining = int(resets_at - now)
                h = remaining // 3600
                m = (remaining % 3600) // 60
                lines.append(f"リセットまで: {h}h{m:02d}m")
            else:
                lines.append("リセット済み")

        age = int(now - updated_at)
        lines.append(f"最終更新: {age}秒前")
        detail.title = " | ".join(lines)

    @rumps.timer(REFRESH_INTERVAL)
    def refresh(self, _):
        self._update()


if __name__ == "__main__":
    ClaudeUsageApp().run()
