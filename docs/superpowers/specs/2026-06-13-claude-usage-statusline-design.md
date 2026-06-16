# Claude Usage Display — 設計仕様

**作成日：** 2026-06-13  
**最終更新：** 2026-06-16  
**ステータス：** 完成

---

## 概要

Claude Code CLIのステータスバーと macOS メニューバーの両方に、現在の5時間レート制限の使用率とリセット時刻を表示するツール群。

Claude for Desktop 使用中も `rate_limit_poller.sh` が15分ごとにバックグラウンドで `used_percentage` と `resets_at` を更新するため、ターミナルを開かなくてもメニューバーが最新情報を表示する。

---

## 表示仕様

### CLIステータスバー（statusLine）

```
📊 28% ⏱ 4h18m でリセット
```

| 要素 | 内容 |
|---|---|
| `28%` | 5時間レート制限の使用率（サーバー提供値） |
| `4h18m でリセット` | レート制限リセットまでの残り時間 |

リセット済みの場合：`📊 0%`

### macOSメニューバー

| 状態 | 表示例 |
|---|---|
| 常時（更新時刻付き） | `📊 28% (2分前) ⏱4h30m` |
| キャッシュなし | `📊 ?` |

クリックで詳細表示：`使用量: 28% | リセットまで: 4h30m | 使用量: 2分前の値 (CLI未使用) | リセット時刻: 14分前更新`

> **注意：** `(X分前)` は `used_percentage` の最終更新時刻を示す。ポーラーが15分ごとに更新するため、最大15分の遅延が生じる。

---

## データソース

### 1. CLIステータスバー stdin（リアルタイム）

Claude Code CLIが `statusLine` スクリプト実行時に **stdin** で渡すJSON。

```json
{
  "rate_limits": {
    "five_hour": {
      "used_percentage": 28,
      "resets_at": 1234567890
    }
  }
}
```

| フィールド | 内容 |
|---|---|
| `used_percentage` | 5時間ウィンドウの使用率（%）。サーバー提供の正確な値 |
| `resets_at` | リセット時刻（Unixタイムスタンプ） |

> **制約：** CLI（`claude`コマンド）のインタラクティブセッション中にのみ発火する。`--print` モードでは発火しない。

### 2. rate_limit_poller.sh による定期更新（15分ごと）

`claude --print --output-format stream-json --verbose` ではなく、Python `pty` モジュールで仮想TTYを作りインタラクティブモードのClaudeを起動してstatusLineを発火させる。

```
理由：claude --print（非インタラクティブ）はstatusLineを発火させないため、
     used_percentage が取得できない。PTY方式ならstatusLineが発火する。
```

---

## ファイル構成

```
claude-usage-display/
├── claude_usage.sh          # CLIステータスライン用スクリプト（settings.jsonから参照）
├── menubar_app.py           # macOSメニューバーアプリ（rumps）→ ~/.claude/ にコピーして実行
├── rate_limit_poller.sh     # 15分ごとバックグラウンドポーリング（PTY方式）→ ~/.claude/ にコピーして実行
├── start_claude.command     # 参考用（現在はLaunchAgentから直接ポーラーを実行するため未使用）
├── install.sh               # 全コンポーネントのセットアップ
└── tests/
    ├── test_token_count.sh  # claude_usage.sh の単体テスト
    ├── test_install.sh      # install.sh の単体テスト
    └── fixtures/            # テスト用フィクスチャ
```

> **重要：** `menubar_app.py` と `rate_limit_poller.sh` は `install.sh` が `~/.claude/` にコピーし、LaunchAgentはそのコピーを参照する。  
> macOSのTCC（プライバシー制限）によりLaunchAgentはDesktopフォルダ等への直接アクセスが制限されるため。

---

## 処理フロー

### `claude_usage.sh`（CLIステータスライン）

1. Claude Code CLIから stdin でJSONを受け取る
2. tmpfileに書き出してPython3で解析（ARG_MAX対策）
   - tmpfileのクリーンアップは `trap 'rm -f "$TMPFILE"' EXIT` で保証（遅延評価クォート）
3. `rate_limits.five_hour.used_percentage` と `resets_at` を取得
4. `resets_at` が現在時刻以前なら `used_percentage` を 0 に補正
5. 表示文字列を stdout に出力
6. 既存キャッシュを読み込んでマージし `~/.claude/claude_usage_cache.json` にアトミック書き込み
   （ポーラーが追加した `resets_at_polled_at` フィールドを上書きしないためマージが必要）
   - キャッシュパスは `CLAUDE_USAGE_CACHE` 環境変数で上書き可能（テスト用）

### `rate_limit_poller.sh`（バックグラウンドポーリング）

LaunchAgent（`com.claude-usage.rate-limit-poller`）が15分ごとに実行。`~/.claude/` からコピーされたものが動く。

1. **アイドル判定**（`FORCE_POLL=1` のときはスキップ）：以下の両方が30分以上更新されていなければスキップ
   - `~/.claude/claude_usage_cache.json` の `updated_at`（CLI活動）
   - `~/Library/Application Support/Claude/buddy-tokens.json` の更新時刻（Desktop活動）
   - 算術差分がマイナスになる（時計ずれ等）場合は「アクティブでない」と判断して安全側に倒す
2. Python `pty.openpty()` で仮想TTYを作成し、`claude`（インタラクティブモード）を起動
3. プロンプト（`❯`）が表示されたらメッセージ（`.`）を送信
4. `claude_usage.sh`（statusLine）が発火して `used_percentage` + `resets_at` がキャッシュに書かれるのを待つ（最大90秒）
5. `finally` ブロックでプロセスkill → `proc.wait(timeout=10)` → PTY master fdのクローズを保証

> **注意：** ポーラー自体のAPI呼び出しはトークンを消費するが、Pro/Maxプランでは追加課金なし（5時間レート制限内での消費）。

### `menubar_app.py`（メニューバーアプリ）

1. 起動時および30秒ごとに `~/.claude/claude_usage_cache.json` を読み込む
2. `updated_at` の経過時間を常に表示：`📊 28% (2分前) ⏱4h30m`
   - `_age_str` は `updated_at` が `None` / `0` の場合「不明」を返す（クラッシュ防止）
3. キャッシュ未存在 → `📊 ?` を表示

### `install.sh`（セットアップ）

以下をワンコマンドで登録。

**スクリプトのコピー（TCC制限対策）：**
```
rate_limit_poller.sh → ~/.claude/rate_limit_poller.sh
menubar_app.py       → ~/.claude/menubar_app.py
```

**python3 の選択：**
- メニューバーアプリ用：`rumps` がインポートできるものを優先探索（`/usr/local/bin/python3` → `/opt/homebrew/bin/python3` → `command -v python3`）
- plist生成用：`rumps` 不要。`command -v python3` で取得し、未検出時は早期終了

**登録内容：**
1. `~/.claude/settings.json` に `statusLine` を登録（`refreshInterval: 30`）
2. `~/.claude/menubar_app.py` を LaunchAgent（`com.claude-usage.menubar`）でログイン時自動起動登録
3. `~/.claude/rate_limit_poller.sh` を LaunchAgent（`com.claude-usage.startup-poll`）でログイン時1回・`FORCE_POLL=1` で登録
4. `~/.claude/rate_limit_poller.sh` を LaunchAgent（`com.claude-usage.rate-limit-poller`）で15分ごと登録

plist生成は `plistlib`（Python標準ライブラリ）を使用し、パスに特殊文字・スペースが含まれても安全なXMLを生成する。

---

## キャッシュファイル仕様

**パス：** `~/.claude/claude_usage_cache.json`

```json
{
  "used_percentage": 28,
  "resets_at": 1234567890.0,
  "remaining_secs": 16200,
  "updated_at": 1234567000.0,
  "resets_at_polled_at": 1234567100.0
}
```

| フィールド | 書き込み元 | 内容 |
|---|---|---|
| `used_percentage` | `claude_usage.sh` / ポーラー | 使用率（%） |
| `resets_at` | `claude_usage.sh` / ポーラー | リセット時刻（Unixタイムスタンプ） |
| `remaining_secs` | `claude_usage.sh` | CLIが計算したリセットまでの秒数 |
| `updated_at` | `claude_usage.sh` | statusLine最終発火時刻 |
| `resets_at_polled_at` | ポーラー | ポーラー最終実行時刻 |

書き込みは `NamedTemporaryFile` + `os.replace` によるアトミック操作。例外発生時は tmpファイルを確実に削除。

---

## LaunchAgent 一覧

| Label | 起動条件 | 実行ファイル | 役割 |
|---|---|---|---|
| `com.claude-usage.menubar` | ログイン時・KeepAlive常駐 | `~/.claude/menubar_app.py` | メニューバーアプリを起動・維持 |
| `com.claude-usage.startup-poll` | ログイン時・1回（`FORCE_POLL=1`）・`ThrottleInterval: 60` | `~/.claude/rate_limit_poller.sh` | 初回キャッシュをバックグラウンドで即時更新 |
| `com.claude-usage.rate-limit-poller` | 15分ごと・`ThrottleInterval: 60` | `~/.claude/rate_limit_poller.sh` | バックグラウンドで使用率を更新 |

全LaunchAgent は `launchctl bootstrap/bootout "gui/$(id -u)"` で登録（macOS Catalina以降の正式API）。

---

## テスト仕様

| テストファイル | 対象 | 主な確認内容 |
|---|---|---|
| `test_token_count.sh` | `claude_usage.sh` | 通常・リセット済み・0%・不正JSON・キーなしの5ケース |
| `test_install.sh` | `install.sh` | statusLine登録・スクリプトコピー・plist生成3種 |

**テストの安全性：**
- `test_token_count.sh`：`CLAUDE_USAGE_CACHE` 環境変数で一時ファイルを指定し本番キャッシュを汚染しない
- `test_install.sh`：`HOME` を一時ディレクトリに差し替え。`launchctl`/`osascript` は `$TMP_BIN/` にファイルモックを配置して `PATH` で優先させる（macOS bash 3.2 で `export -f` が不安定なため）

---

## 依存関係

| ツール | 用途 | 入手方法 |
|---|---|---|
| bash | スクリプト実行 | macOS標準 |
| python3（Homebrew推奨） | JSON解析・キャッシュ書き込み・PTY制御・plist生成 | `/usr/local/bin/python3` 等 |
| python3 + rumps | メニューバーアプリ | `pip3 install rumps --break-system-packages` |
| launchctl | LaunchAgent登録 | macOS標準 |

---

## 制約・考慮事項

- `statusLine` はCLIでワークスペース信頼を一度受け入れるまで動作しない
- `claude --print`（非インタラクティブ）はstatusLineを発火させないため、ポーラーはPTY方式を採用
- ポーラーの `CLAUDE_BIN` は環境変数で上書き可能（デフォルト: `$HOME/.local/bin/claude`）
- `refreshInterval: 30` により CLI使用中は30秒ごとにキャッシュが更新される
- ポーラーは30分アイドル（CLI・Desktop両方とも未活動）の場合スキップして不要なトークン消費を抑制
- LaunchAgentはDesktopフォルダ等へのTCCアクセス制限があるため、スクリプトは `~/.claude/` にコピーして実行する
- `which python3` ではなく `rumps` のインポート可否で python3 を選択する（Homebrew版と macOS標準版が共存する環境のため）
- macOSのTerminalウィンドウはウィンドウ内のプロセスから自己クローズできない（osascriptを実行するプロセス自身が「実行中プロセス」として検出されるため）→ LaunchAgentから直接スクリプトを実行する方式に変更
