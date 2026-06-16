#!/usr/bin/env bash
# ログイン時にキャッシュを初期化してTerminalを閉じる
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FORCE_POLL=1 bash "$SCRIPT_DIR/rate_limit_poller.sh"
osascript -e 'tell application "Terminal" to close front window' 2>/dev/null || true
