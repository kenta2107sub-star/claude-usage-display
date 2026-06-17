#!/usr/bin/env bash
# バックグラウンドで claude を PTY 起動し statusLine を発火させてキャッシュを更新する。
# Terminal 不要。LaunchAgent から直接呼ばれる。

set -euo pipefail

CACHE_FILE="$HOME/.claude/claude_usage_cache.json"
BUDDY_TOKENS="$HOME/Library/Application Support/Claude/buddy-tokens.json"
IDLE_THRESHOLD=1800  # 30分（秒）
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
# PYTHON3_BIN は install.sh がコピー時に絶対パスに書き換える（LaunchAgent の PATH 対策）
PYTHON3_BIN="${PYTHON3_BIN:-python3}"

# アクティビティ確認：CLI または Desktop が 30 分以内に動いていれば実行する
check_activity() {
    local now
    now=$(date +%s)

    if [ -f "$CACHE_FILE" ]; then
        local cli_updated
        cli_updated=$("$PYTHON3_BIN" - "$CACHE_FILE" <<'PYEOF' 2>/dev/null || echo 0
import json, sys
try:
    d=json.load(open(sys.argv[1]))
    print(int(d.get('updated_at', 0)))
except Exception:
    print(0)
PYEOF
)
        local diff=$(( now - cli_updated ))
        if [ "$diff" -ge 0 ] && [ "$diff" -le "$IDLE_THRESHOLD" ]; then
            return 0
        fi
    fi

    if [ -f "$BUDDY_TOKENS" ]; then
        local desktop_modified
        desktop_modified=$(stat -f %m "$BUDDY_TOKENS" 2>/dev/null || echo 0)
        local desktop_diff=$(( now - desktop_modified ))
        if [ "$desktop_diff" -ge 0 ] && [ "$desktop_diff" -le "$IDLE_THRESHOLD" ]; then
            return 0
        fi
    fi

    return 1  # アイドル
}

if [ "${FORCE_POLL:-0}" != "1" ] && ! check_activity; then
    exit 0
fi

export PATH="$HOME/.local/bin:$PATH"
"$PYTHON3_BIN" - "$CACHE_FILE" "$CLAUDE_BIN" <<'PYEOF'
import pty, os, select, time, subprocess, json, sys, struct
from pathlib import Path
import fcntl, termios

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

# PTY ウィンドウサイズを設定（デフォルト 0x0 では TUI がハングする）
fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))

def _setup_slave_tty():
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

proc = subprocess.Popen(
    [claude_bin],
    stdin=slave, stdout=slave, stderr=slave,
    close_fds=True,
    preexec_fn=_setup_slave_tty,
    cwd=home,
    env={**os.environ, 'PATH': f'{home}/.local/bin:/usr/local/bin:/usr/bin:/bin'}
)
os.close(slave)

def respond_to_queries(master_fd, data):
    """端末クエリに応答する（claude が応答待ちでブロックするのを防ぐ）"""
    try:
        # Primary DA (CSI c) → VT220 応答
        if b'\x1b[c' in data:
            os.write(master_fd, b'\x1b[?62;1;22c')
        # Secondary DA (CSI > c)
        if b'\x1b[>0c' in data or b'\x1b[>c' in data:
            os.write(master_fd, b'\x1b[>1;95;0c')
        # XTVERSION (CSI > q)
        if b'\x1b[>0q' in data or b'\x1b[>q' in data:
            os.write(master_fd, b'\x1bP>|xterm(370)\x1b\\')
        # Kitty keyboard protocol query
        if b'\x1b[?u' in data:
            os.write(master_fd, b'\x1b[?0u')
        # Focus tracking: focus-in イベントを送る
        if b'\x1b[?1004h' in data:
            os.write(master_fd, b'\x1b[I')
    except OSError:
        pass

try:
    # ❯ プロンプトが出るまで待つ（最大 120 秒：LaunchAgent コールドスタート対応）
    output = b""
    start = time.time()
    while time.time() - start < 120:
        r, _, _ = select.select([master], [], [], 0.5)
        if r:
            try:
                chunk = os.read(master, 4096)
                output += chunk
                respond_to_queries(master, chunk)
            except OSError:
                sys.exit(1)
        if b'\xe2\x9d\xaf' in output:  # ❯
            break

    if b'\xe2\x9d\xaf' not in output:
        sys.exit(0)  # プロンプト未検出：次回に持ち越し

    time.sleep(0.5)
    try:
        # TUI は raw モードで動作するため Enter キーは CR (\r)。LF (\n) では送信されない。
        os.write(master, b'.\r')
    except OSError:
        sys.exit(1)

    # statusLine 発火（updated_at 更新）を最大 120 秒待つ
    start = time.time()
    while time.time() - start < 120:
        if get_updated_at() != before_updated:
            break
        r, _, _ = select.select([master], [], [], 1)
        if r:
            try:
                chunk = os.read(master, 4096)
                respond_to_queries(master, chunk)
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
