# Claude Usage Display — 設計仕様

**作成日：** 2026-06-13  
**最終更新：** 2026-06-15  
**ステータス：** 完成

---

## 概要

Claude Code CLIのステータスバーと macOS メニューバーの両方に、現在の5時間レート制限の使用率とリセット時刻を表示するツール群。

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
| CLI使用から5分以内（正確） | `📊 28% ⏱4h30m` |
| CLI未使用（最終既知値） | `📊 28% (2時間前)` |
| キャッシュなし | `📊 ?` |

クリックで詳細表示：`使用量: 28% [正確(CLI)] | リセットまで: 4h30m | 最終更新: 45秒前`

---

## データソース

Claude Code CLIが `statusLine` スクリプト実行時に **stdin** で渡すJSONを使用する。

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

> **注意：** このデータはCLI（`claude`コマンド）経由でのみ取得可能。Claude for Desktop単独使用時はデータが更新されない。

---

## ファイル構成

```
claude-usage-display/
├── claude_usage.sh          # CLIステータスライン用スクリプト
├── menubar_app.py           # macOSメニューバーアプリ（rumps）
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
6. キャッシュを `~/.claude/claude_usage_cache.json` にアトミック書き込み

### `menubar_app.py`（メニューバーアプリ）

1. 起動時および30秒ごとに `~/.claude/claude_usage_cache.json` を読み込む
2. キャッシュが5分以内かつ `resets_at` が未来 → **正確モード**（サーバー値をそのまま表示）
3. それ以外 → **最終既知値モード**（最後の値に経過時間を付けて表示）
4. キャッシュ未存在 → `📊 ?` を表示

### `start_claude.command`（ログイン時自動起動）

LaunchAgent（`com.claude-usage.cli-terminal`）が `/usr/bin/open -a Terminal` 経由で起動。
AppleScript Automation権限不要。Terminal が `.command` 拡張子を自動実行する仕組みを利用。

### `install.sh`（セットアップ）

以下をワンコマンドで登録：

1. `~/.claude/settings.json` に `statusLine` を登録
   ```json
   "statusLine": {
     "type": "command",
     "command": "/path/to/claude_usage.sh",
     "refreshInterval": 30
   }
   ```
2. `menubar_app.py` を LaunchAgent（`com.claude-usage.menubar`）でログイン時自動起動登録
3. `start_claude.command` を LaunchAgent（`com.claude-usage.cli-terminal`）で登録

---

## キャッシュファイル仕様

**パス：** `~/.claude/claude_usage_cache.json`

```json
{
  "used_percentage": 28,
  "resets_at": 1234567890,
  "remaining_secs": 16200,
  "updated_at": 1234567000
}
```

書き込みは `NamedTemporaryFile` + `os.replace` によるアトミック操作。

---

## 依存関係

| ツール | 用途 | 入手方法 |
|---|---|---|
| bash | スクリプト実行 | macOS標準 |
| python3 | JSON解析・キャッシュ書き込み | macOS標準 |
| python3 + rumps | メニューバーアプリ | `pip3 install rumps --break-system-packages` |
| launchctl | LaunchAgent登録 | macOS標準 |

---

## 制約・考慮事項

- `used_percentage` / `resets_at` はCLI（statusLine stdin）経由でのみ取得可能。Claude for Desktop単独使用時は最終既知値を表示する
- statusLine はCLIでワークスペース信頼を一度受け入れるまで動作しない
- `refreshInterval: 30` により30秒ごとにキャッシュが更新される
- キャッシュが5分以上古い場合はメニューバーに `(X時間前)` を表示してデータの鮮度を伝える
- LaunchAgent はユーザーセッション（`gui/$(id -u)`）で `bootstrap/bootout` を使用（macOS Catalina以降の正式API）
