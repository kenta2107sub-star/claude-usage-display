#!/usr/bin/env bash
# バックグラウンドでclaudeをPTY起動しstatusLineを発火させてキャッシュを更新する。
# ターミナル不要。LaunchAgentから直接呼ばれる。

set -euo pipefail

CACHE_FILE="$HOME/.claude/claude_usage_cache.json"
BUDDY_TOKENS="$HOME/Library/Application Support/Claude/buddy-tokens.json"
IDLE_THRESHOLD=1800  # 30分（秒）
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"

# アクティビティ確認：CLI または Desktop が30分以内に動いていれば実行する
check_activity() {
    local now
    now=$(date +%s)

    # CLI活動：claude_usage_cache.json の updated_at を確認（C-2修正: 引数渡し）
    if [ -f "$CACHE_FILE" ]; then
        local cli_updated
        cli_updated=$(python3 - "$CACHE_FILE" <<'PYEOF' 2>/dev/null || echo 0
import json, sys
try:
    d=json.load(open(sys.argv[1]))
    print(int(d.get('updated_at', 0)))
except Exception:
    print(0)
PYEOF
)
        if [ $(( now - cli_updated )) -le $IDLE_THRESHOLD ]; then
            return 0
        fi
    fi

    # Desktop活動：buddy-tokens.json のファイル更新時刻を確認
    if [ -f "$BUDDY_TOKENS" ]; then
        local desktop_modified
        desktop_modified=$(stat -f %m "$BUDDY_TOKENS" 2>/dev/null || echo 0)
        if [ $(( now - desktop_modified )) -le $IDLE_THRESHOLD ]; then
            return 0
        fi
    fi

    return 1  # アイドル
}

if [ "${FORCE_POLL:-0}" != "1" ] && ! check_activity; then
    exit 0
fi

# Python PTY でclaudeを起動しstatusLineを発火させる
# C-1修正: ユーザー名ハードコードを $HOME/$CLAUDE_BIN で解決し引数として渡す
PATH="$HOME/.local/bin:$PATH" python3 - "$CACHE_FILE" "$CLAUDE_BIN" <<'PYEOF'
import pty, os, select, time, subprocess, json, sys
from pathlib import Path

cache_path = Path(sys.argv[1])
claude_bin = sys.argv[2]
home = str(Path.home())

def get_updated_at():
    try:
        return json.loads(cache_path.read_text()).get('updated_at', 0)
    except Exception:
        return 0

before_updated = get_updated_at()

master, slave = pty.openpty()
proc = subprocess.Popen(
    [claude_bin],
    stdin=slave, stdout=slave, stderr=slave,
    close_fds=True,
    env={**os.environ, 'PATH': f'{home}/.local/bin:/usr/local/bin:/usr/bin:/bin'}
)
os.close(slave)

# I-3修正: finally で必ず master を閉じる
try:
    # プロンプト（❯）が出るまで待つ（最大15秒）
    output = b""
    start = time.time()
    while time.time() - start < 15:
        r, _, _ = select.select([master], [], [], 0.5)
        if r:
            try:
                output += os.read(master, 4096)
            except OSError:
                break
        if b'\xe2\x9d\xaf' in output:  # ❯
            break

    # メッセージ送信
    time.sleep(1)
    try:
        os.write(master, b'.\n')
    except OSError:
        sys.exit(1)

    # statusLine発火（updated_at更新）を最大90秒待つ
    start = time.time()
    while time.time() - start < 90:
        if get_updated_at() != before_updated:
            break
        r, _, _ = select.select([master], [], [], 1)
        if r:
            try:
                os.read(master, 4096)
            except OSError:
                break
        time.sleep(0.5)

finally:
    try:
        proc.kill()
    except OSError:
        pass
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    try:
        os.close(master)
    except OSError:
        pass
PYEOF
