#!/usr/bin/env bash
# バックグラウンドでclaudeをPTY起動しstatusLineを発火させてキャッシュを更新する。
# ターミナル不要。LaunchAgentから直接呼ばれる。

set -euo pipefail

CACHE_FILE="$HOME/.claude/claude_usage_cache.json"
BUDDY_TOKENS="$HOME/Library/Application Support/Claude/buddy-tokens.json"
IDLE_THRESHOLD=1800  # 30分（秒）
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
# PYTHON3_BIN はinstall.shがコピー時に絶対パスに書き換える（LaunchAgentのPATH対策）
PYTHON3_BIN="${PYTHON3_BIN:-python3}"

# アクティビティ確認：CLI または Desktop が30分以内に動いていれば実行する
check_activity() {
    local now
    now=$(date +%s)

    # CLI活動：claude_usage_cache.json の updated_at を確認（C-2修正: 引数渡し）
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

    # Desktop活動：buddy-tokens.json のファイル更新時刻を確認
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

# Python PTY でclaudeを起動しstatusLineを発火させる
# C-1修正: ユーザー名ハードコードを $HOME/$CLAUDE_BIN で解決し引数として渡す
export PATH="$HOME/.local/bin:$PATH"
"$PYTHON3_BIN" - "$CACHE_FILE" "$CLAUDE_BIN" <<'PYEOF'
import pty, os, select, time, subprocess, json, sys, signal, struct
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

import datetime
_pid = os.getpid()
_dbg = open('/tmp/claude_pty_debug.log', 'a')
def dbg(msg): _dbg.write(f"{datetime.datetime.now().isoformat()} [{_pid}] {msg}\n"); _dbg.flush()

dbg(f"start claude_bin={claude_bin} cache={cache_path} env_PATH={os.environ.get('PATH','')}")

import fcntl, termios

# シグナルハンドラ（デバッグ用）
def _sig_handler(signum, frame):
    dbg(f"received signal {signum}")
    sys.exit(128 + signum)
signal.signal(signal.SIGTERM, _sig_handler)
signal.signal(signal.SIGINT, _sig_handler)

master, slave = pty.openpty()

# PTYウィンドウサイズを80x24に設定（TUIアプリは0x0だとハングする）
winsize = struct.pack('HHHH', 24, 80, 0, 0)  # rows, cols, xpixels, ypixels
fcntl.ioctl(master, termios.TIOCSWINSZ, winsize)
dbg("set window size to 80x24")

def _setup_slave_tty():
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

proc = subprocess.Popen(
    [claude_bin, '--dangerously-skip-permissions'],
    stdin=slave, stdout=slave, stderr=slave,
    close_fds=True,
    preexec_fn=_setup_slave_tty,
    cwd=home,
    env={**os.environ, 'PATH': f'{home}/.local/bin:/usr/local/bin:/usr/bin:/bin'}
)
os.close(slave)
dbg(f"claude pid={proc.pid}")

def respond_to_queries(master_fd, data):
    """端末クエリに応答する（claudeが応答を待って停止するのを防ぐ）"""
    try:
        if b'\x1b[c' in data:
            os.write(master_fd, b'\x1b[?62;1;22c')
        if b'\x1b[>0c' in data or b'\x1b[>c' in data:
            os.write(master_fd, b'\x1b[>1;95;0c')
        if b'\x1b[>0q' in data or b'\x1b[>q' in data:
            os.write(master_fd, b'\x1bP>|xterm(370)\x1b\\')
        if b'\x1b[?u' in data:
            os.write(master_fd, b'\x1b[?0u')
        if b'\x1b[?1004h' in data:
            os.write(master_fd, b'\x1b[I')
    except OSError:
        pass

try:
    # プロンプト（❯）が出るまで待つ（最大30秒）
    output = b""
    start = time.time()
    while time.time() - start < 30:
        r, _, _ = select.select([master], [], [], 0.5)
        if r:
            try:
                chunk = os.read(master, 4096)
                output += chunk
                respond_to_queries(master, chunk)
                dbg(f"read {len(chunk)}b prompt_found={'❯' in output.decode('utf-8','replace')}")
            except OSError:
                dbg("OSError reading master (slave closed)")
                break
        if b'\xe2\x9d\xaf' in output:  # ❯
            break

    proc_state = proc.poll()
    dbg(f"sending message, proc_state={proc_state} output_so_far={repr(output[:200])}")
    time.sleep(0.5)
    try:
        # CR (\r) がraw modeのTUIでのEnterキー。LF (\n) ではサブミットされない。
        os.write(master, b'.\r')
        dbg("sent .CR to master")
    except OSError:
        dbg("OSError writing to master")
        sys.exit(1)

    # statusLine発火（updated_at更新）を最大120秒待つ
    start = time.time()
    loop_iter = 0
    while time.time() - start < 120:
        loop_iter += 1
        elapsed = time.time() - start
        current = get_updated_at()
        if current != before_updated:
            dbg(f"cache updated! iter={loop_iter} elapsed={elapsed:.1f}s {before_updated} -> {current}")
            break
        r, _, _ = select.select([master], [], [], 1)
        if r:
            try:
                chunk = os.read(master, 4096)
                dbg(f"wait loop iter={loop_iter} elapsed={elapsed:.1f}s read {len(chunk)}b: {repr(chunk[:200])}")
                respond_to_queries(master, chunk)
            except OSError:
                dbg(f"wait loop OSError iter={loop_iter} elapsed={elapsed:.1f}s proc={proc.poll()}")
                break
        else:
            # データなし時は10イテレーションごとにログ
            if loop_iter % 10 == 0:
                dbg(f"wait loop no data iter={loop_iter} elapsed={elapsed:.1f}s proc={proc.poll()}")
        time.sleep(0.5)

    elapsed_final = time.time() - start
    dbg(f"wait loop done after {elapsed_final:.1f}s iter={loop_iter}, cache_updated={get_updated_at() != before_updated}")

finally:
    dbg("finally block")
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
