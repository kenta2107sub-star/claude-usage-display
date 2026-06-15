#!/usr/bin/env bash
# Terminal が .command ファイルを開くと自動でこのスクリプトが実行される
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
"$HOME/.local/bin/claude"
