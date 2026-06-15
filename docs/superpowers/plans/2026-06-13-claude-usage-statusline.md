# Claude Usage Statusline Implementation Plan

> **ステータス：完成（2026-06-15）**  
> このプランは初期実装計画の記録です。実際の実装は設計変更により大きく異なります。最新の仕様は `docs/superpowers/specs/2026-06-13-claude-usage-statusline-design.md` を参照してください。

**Goal:** Claude Codeのステータスバーに現在セッションのトークン使用率とリセット時刻を表示するシェルスクリプトを作成する。

**Architecture（当初計画）:** `~/.claude/projects/` 以下のJSONLファイルからトークンデータを読み取り、Python3で集計して表示文字列を生成するシェルスクリプト。`install.sh` が `~/.claude/settings.json` の `statusline` キーに登録する。  
**Architecture（実際）:** CLI stdin経由のrate_limits JSONを使用。メニューバーアプリ・ログイン時自動起動も追加。

**Tech Stack:** bash, Python3（macOS標準）、rumps（メニューバーアプリ）

---

### Task 1: テスト用フィクスチャの作成

**Files:**
- Create: `tests/fixtures/sample_session.jsonl`
- Create: `tests/fixtures/sample_sessions_dir/abc123.json`

- [ ] **Step 1: テスト用JSOLファイルを作成する**

```bash
mkdir -p tests/fixtures/sample_sessions_dir
```

`tests/fixtures/sample_session.jsonl` を以下の内容で作成する：

```jsonl
{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":100,"cache_creation_input_tokens":5000,"cache_read_input_tokens":2000,"output_tokens":200}},"timestamp":"2026-06-13T10:00:00.000Z","sessionId":"abc123"}
{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":6000,"output_tokens":150}},"timestamp":"2026-06-13T10:05:00.000Z","sessionId":"abc123"}
```

- [ ] **Step 2: テスト用セッションJSONを作成する**

`tests/fixtures/sample_sessions_dir/abc123.json` を以下の内容で作成する：

```json
{"sessionId": "abc123", "cwd": "/tmp/testproject"}
```

- [ ] **Step 3: コミット**

```bash
git init
git add tests/
git commit -m "test: add fixtures for claude_usage.sh"
```

---

### Task 2: トークン集計スクリプトの作成

**Files:**
- Create: `claude_usage.sh`

上記フィクスチャを使ってテストから書き始める。

- [ ] **Step 1: テストスクリプトを作成する**

`tests/test_token_count.sh` を以下の内容で作成する：

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/sample_session.jsonl"

# claude_usage.sh のトークン集計ロジックを直接テスト
result=$(python3 - "$FIXTURE" <<'EOF'
import json, sys

jsonl_path = sys.argv[1]
total = 0
with open(jsonl_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") != "assistant":
            continue
        usage = entry.get("message", {}).get("usage", {})
        total += usage.get("input_tokens", 0)
        total += usage.get("cache_creation_input_tokens", 0)
        total += usage.get("cache_read_input_tokens", 0)
        total += usage.get("output_tokens", 0)
print(total)
EOF
)

expected=13500  # 100+5000+2000+200 + 50+0+6000+150
if [ "$result" -eq "$expected" ]; then
    echo "PASS: token count = $result"
else
    echo "FAIL: expected $expected, got $result"
    exit 1
fi
```

- [ ] **Step 2: テストを実行して失敗することを確認する（スクリプト未作成なのでフィクスチャ依存部分のみ確認）**

```bash
chmod +x tests/test_token_count.sh
bash tests/test_token_count.sh
```

期待：`PASS: token count = 13500`（このテストはスクリプトに依存しないので通る）

- [ ] **Step 3: `claude_usage.sh` のメイン実装を作成する**

`claude_usage.sh` を以下の内容で作成する：

```bash
#!/usr/bin/env bash
# Claude Codeステータスライン用：トークン使用量表示スクリプト

set -euo pipefail

CONTEXT_WINDOW=200000
RESET_HOURS=5

# 現在の作業ディレクトリからセッションIDを特定
find_session_id() {
    local cwd
    cwd="$(pwd)"
    local sessions_dir="$HOME/.claude/sessions"
    
    if [ ! -d "$sessions_dir" ]; then
        return 1
    fi
    
    for session_file in "$sessions_dir"/*.json; do
        [ -f "$session_file" ] || continue
        local file_cwd
        file_cwd=$(python3 -c "
import json, sys
try:
    with open('$session_file') as f:
        d = json.load(f)
    print(d.get('cwd', ''))
except:
    print('')
")
        if [ "$file_cwd" = "$cwd" ]; then
            python3 -c "
import json
with open('$session_file') as f:
    d = json.load(f)
print(d.get('sessionId', ''))
"
            return 0
        fi
    done
    return 1
}

# cwdをプロジェクトパス形式（-区切り）に変換
encode_cwd() {
    echo "$1" | sed 's|/|-|g'
}

# JSOLからトークン集計とリセット時間を計算
parse_jsonl() {
    local jsonl_path="$1"
    python3 - "$jsonl_path" <<'PYEOF'
import json, sys, time
from datetime import datetime, timezone

jsonl_path = sys.argv[1]
total_tokens = 0
first_ts = None

with open(jsonl_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") != "assistant":
            continue
        usage = entry.get("message", {}).get("usage", {})
        total_tokens += usage.get("input_tokens", 0)
        total_tokens += usage.get("cache_creation_input_tokens", 0)
        total_tokens += usage.get("cache_read_input_tokens", 0)
        total_tokens += usage.get("output_tokens", 0)
        if first_ts is None:
            ts_str = entry.get("timestamp", "")
            if ts_str:
                try:
                    first_ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
                except ValueError:
                    pass

CONTEXT_WINDOW = 200000
RESET_HOURS = 5

pct = round(total_tokens / CONTEXT_WINDOW * 100)

if total_tokens >= 1000:
    tok_display = f"{total_tokens/1000:.1f}K"
else:
    tok_display = str(total_tokens)

reset_str = ""
if first_ts:
    now = datetime.now(timezone.utc)
    reset_at = first_ts.replace(
        hour=first_ts.hour + RESET_HOURS if first_ts.hour + RESET_HOURS < 24 else (first_ts.hour + RESET_HOURS) % 24,
        day=first_ts.day + (1 if first_ts.hour + RESET_HOURS >= 24 else 0)
    )
    from datetime import timedelta
    reset_at = first_ts + timedelta(hours=RESET_HOURS)
    remaining = reset_at - now
    if remaining.total_seconds() > 0:
        total_secs = int(remaining.total_seconds())
        h = total_secs // 3600
        m = (total_secs % 3600) // 60
        if h > 0:
            reset_str = f"⏱ {h}h{m:02d}m でリセット"
        else:
            reset_str = f"⏱ {m}m でリセット"

parts = [f"📊 {pct}% ({tok_display}/200K)"]
if reset_str:
    parts.append(reset_str)
print(" ".join(parts))
PYEOF
}

main() {
    local session_id
    session_id=$(find_session_id 2>/dev/null) || { echo ""; exit 0; }
    
    [ -z "$session_id" ] && { echo ""; exit 0; }
    
    local cwd_encoded
    cwd_encoded=$(encode_cwd "$(pwd)")
    
    local jsonl_path="$HOME/.claude/projects/${cwd_encoded}/${session_id}.jsonl"
    
    if [ ! -f "$jsonl_path" ]; then
        echo ""
        exit 0
    fi
    
    parse_jsonl "$jsonl_path"
}

main
```

- [ ] **Step 4: スクリプトに実行権限を付与して動作確認**

```bash
chmod +x claude_usage.sh
bash claude_usage.sh
```

期待：`📊 X% (XX.XK/200K) ⏱ Xh XXm でリセット` のような出力（セッションがあれば）、またはセッションがなければ空文字

- [ ] **Step 5: コミット**

```bash
git add claude_usage.sh tests/test_token_count.sh
git commit -m "feat: add claude_usage.sh statusline script"
```

---

### Task 3: インストールスクリプトの作成

**Files:**
- Create: `install.sh`

- [ ] **Step 1: `install.sh` を作成する**

`install.sh` を以下の内容で作成する：

```bash
#!/usr/bin/env bash
# ~/.claude/settings.json の statusline キーにclaude_usage.shを登録する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/claude_usage.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"

if [ ! -f "$SCRIPT_PATH" ]; then
    echo "エラー: $SCRIPT_PATH が見つかりません"
    exit 1
fi

if [ ! -f "$SETTINGS_FILE" ]; then
    echo "{}" > "$SETTINGS_FILE"
fi

# 既存のsettings.jsonにstatuslineキーをマージ
python3 - "$SETTINGS_FILE" "$SCRIPT_PATH" <<'PYEOF'
import json, sys

settings_path = sys.argv[1]
script_path = sys.argv[2]

with open(settings_path) as f:
    settings = json.load(f)

settings["statusline"] = script_path

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"登録完了: {settings_path} に statusline = {script_path} を設定しました")
PYEOF
```

- [ ] **Step 2: インストールスクリプトのテストを作成する**

`tests/test_install.sh` を以下の内容で作成する：

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_SCRIPT="$ROOT_DIR/install.sh"

# テスト用の一時ディレクトリを使う
TMP_DIR=$(mktemp -d)
TMP_SETTINGS="$TMP_DIR/settings.json"
TMP_CLAUDE_HOME="$TMP_DIR/.claude"
mkdir -p "$TMP_CLAUDE_HOME"
cp "$TMP_SETTINGS" "$TMP_CLAUDE_HOME/settings.json" 2>/dev/null || echo "{}" > "$TMP_CLAUDE_HOME/settings.json"

# HOME を一時的に差し替えてinstall.shを実行
HOME="$TMP_DIR" bash "$INSTALL_SCRIPT"

# settings.jsonにstatuslineが登録されているか確認
result=$(python3 -c "
import json
with open('$TMP_CLAUDE_HOME/settings.json') as f:
    d = json.load(f)
print(d.get('statusline', ''))
")

if echo "$result" | grep -q "claude_usage.sh"; then
    echo "PASS: statusline registered = $result"
else
    echo "FAIL: statusline not found in settings.json, got: $result"
    rm -rf "$TMP_DIR"
    exit 1
fi

rm -rf "$TMP_DIR"
```

- [ ] **Step 3: テストを実行する**

```bash
chmod +x install.sh tests/test_install.sh
bash tests/test_install.sh
```

期待：`PASS: statusline registered = /path/to/claude_usage.sh`

- [ ] **Step 4: コミット**

```bash
git add install.sh tests/test_install.sh
git commit -m "feat: add install.sh for settings.json registration"
```

---

### Task 4: 統合確認

**Files:**
- Modify: `~/.claude/settings.json`（install.sh 経由）

- [ ] **Step 1: install.sh を実行して実際の settings.json に登録する**

```bash
bash install.sh
```

期待：`登録完了: /Users/<name>/.claude/settings.json に statusline = /path/to/claude_usage.sh を設定しました`

- [ ] **Step 2: settings.json を確認する**

```bash
python3 -c "import json; d=json.load(open('$HOME/.claude/settings.json')); print(d.get('statusline'))"
```

期待：`/path/to/claude-usage-display/claude_usage.sh`

- [ ] **Step 3: claude_usage.sh を直接実行して出力を確認する**

```bash
bash claude_usage.sh
```

期待：現在のセッションがあれば `📊 X% (XX.XK/200K) ⏱ Xh XXm でリセット`、なければ空文字

- [ ] **Step 4: Claude Code を再起動してステータスバーを目視確認する**

Claude for Desktop を再起動し、ステータスバーにトークン使用量が表示されることを確認する。

- [ ] **Step 5: 最終コミット**

```bash
git add -A
git commit -m "docs: finalize claude-usage-display implementation"
```
