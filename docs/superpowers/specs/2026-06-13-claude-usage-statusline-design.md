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
├── claude_usage.sh          # CLIステータスライン用スクリプト
├── menubar_app.py           # macOSメニューバーアプリ（rumps）
├── rate_limit_poller.sh     # 15分ごとバックグラウンドポーリング（PTY方式）
├── start_claude.command     # ログイン時Terminal起動スクリプト
├── install.sh               # 全コンポーネントのセットアップ
├── launch_claude_terminal.sh  # ログイン起動の参考スクリプト（未使用）
└── tests/
    ├── test_token_count.sh  # claude_usage.sh の単体テスト
    ├── test_install.sh      # install.sh の単体テスト
    └── fixtures/            # テスト用フィクスチャ
```

---

## 処理フロー

### `claude_usage.sh`（CLIステータスライン）

1. Claude Code CLIから stdin でJSONを受け取る
2. tmpfileに書き出してPython3で解析（ARG_MAX対策）
3. `rate_limits.five_hour.used_percentage` と `resets_at` を取得
4. `resets_at` が現在時刻以前なら `used_percentage` を 0 に補正
5. 表示文字列を stdout に出力
6. 既存キャッシュを読み込んでマージし `~/.claude/claude_usage_cache.json` にアトミック書き込み
   （ポーラーが追加した `resets_at_polled_at` フィールドを上書きしないためマージが必要）

### `rate_limit_poller.sh`（バックグラウンドポーリング）

LaunchAgent（`com.claude-usage.rate-limit-poller`）が15分ごとに実行。

1. **アイドル判定**：以下の両方が30分以上更新されていなければスキップ
   - `~/.claude/claude_usage_cache.json` の `updated_at`（CLI活動）
   - `~/Library/Application Support/Claude/buddy-tokens.json` の更新時刻（Desktop活動）
2. Python `pty.openpty()` で仮想TTYを作成し、`claude`（インタラクティブモード）を起動
3. プロンプト（`❯`）が表示されたらメッセージ（`.`）を送信
4. `claude_usage.sh`（statusLine）が発火して `used_percentage` + `resets_at` がキャッシュに書かれるのを待つ（最大90秒）
5. `finally` ブロックでプロセスkillとPTY master fdのクローズを保証

> **注意：** ポーラー自体のAPI呼び出しはトークンを消費するが、Pro/Maxプランでは追加課金なし（5時間レート制限内での消費）。

### `menubar_app.py`（メニューバーアプリ）

1. 起動時および30秒ごとに `~/.claude/claude_usage_cache.json` を読み込む
2. `updated_at` の経過時間を常に表示：`📊 28% (2分前) ⏱4h30m`
3. キャッシュ未存在 → `📊 ?` を表示

### `start_claude.command`（ログイン時自動起動）

LaunchAgent（`com.claude-usage.cli-terminal`）が `/usr/bin/open -a Terminal` 経由で起動。
AppleScript Automation権限不要。Terminal が `.command` 拡張子を自動実行する仕組みを利用。

### `install.sh`（セットアップ）

以下をワンコマンドで登録。plist生成は `plistlib`（Python標準ライブラリ）を使用し、パスに特殊文字・スペースが含まれても安全なXMLを生成する。

1. `~/.claude/settings.json` に `statusLine` を登録
   ```json
   "statusLine": {
     "type": "command",
     "command": "/path/to/claude_usage.sh",
     "refreshInterval": 30
   }
   ```
2. `menubar_app.py` を LaunchAgent（`com.claude-usage.menubar`）でログイン時自動起動登録
3. `rate_limit_poller.sh` を LaunchAgent（`com.claude-usage.startup-poll`）でログイン時1回・FORCE_POLL=1で登録
4. `rate_limit_poller.sh` を LaunchAgent（`com.claude-usage.rate-limit-poller`）で15分ごと登録

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

## install.sh のセキュリティ注意事項

`chmod` の実行は `python3 -c "os.chmod('$PATH', ...)"` ではなく引数渡し方式（heredoc + `sys.argv`）を使用する。パスにシングルクォートや特殊文字が含まれる場合のコードインジェクションを防ぐため。

---

## LaunchAgent 一覧

| Label | 起動条件 | 役割 |
|---|---|---|
| `com.claude-usage.menubar` | ログイン時・常駐 | メニューバーアプリを起動・維持 |
| `com.claude-usage.startup-poll` | ログイン時・1回（FORCE_POLL=1） | 初回キャッシュをバックグラウンドで即時更新 |
| `com.claude-usage.rate-limit-poller` | 15分ごと | バックグラウンドで使用率を更新 |

全LaunchAgent は `launchctl bootstrap/bootout "gui/$(id -u)"` で登録（macOS Catalina以降の正式API）。  
ポーラーには `ThrottleInterval: 60` を設定し、クラッシュ時の無限即時再起動を防止。

---

## 依存関係

| ツール | 用途 | 入手方法 |
|---|---|---|
| bash | スクリプト実行 | macOS標準 |
| python3 | JSON解析・キャッシュ書き込み・PTY制御 | macOS標準 |
| python3 + rumps | メニューバーアプリ | `pip3 install rumps --break-system-packages` |
| launchctl | LaunchAgent登録 | macOS標準 |

---

## 制約・考慮事項

- `statusLine` はCLIでワークスペース信頼を一度受け入れるまで動作しない
- `claude --print`（非インタラクティブ）はstatusLineを発火させないため、ポーラーはPTY方式を採用
- ポーラーの `CLAUDE_BIN` は環境変数で上書き可能（デフォルト: `$HOME/.local/bin/claude`）
- `refreshInterval: 30` により CLI使用中は30秒ごとにキャッシュが更新される
- ポーラーは30分アイドル（CLI・Desktop両方とも未活動）の場合スキップして不要なトークン消費を抑制
- LaunchAgent plistの生成は `plistlib` を使用し、パスの特殊文字・スペースに対して安全
