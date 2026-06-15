# claude-usage-display

Claude Code の5時間レート制限の使用量を **CLIステータスバー** と **macOSメニューバー** に表示するツールです。

![CLI statusLine example](https://img.shields.io/badge/📊%2028%25%20⏱4h30m-green)

---

## 機能

- **CLIステータスバー** — `claude` コマンド使用中、入力欄の下に使用率とリセット時刻をリアルタイム表示
- **macOSメニューバーアプリ** — Claude for Desktop 使用中もメニューバーに常時表示
- **ログイン時自動起動** — PC起動時にTerminalで `claude` CLIを自動起動し、データを常に最新に保つ

---

## 必要環境

- macOS
- Claude Code CLI（`~/.local/bin/claude`）
- Python 3.x（macOS標準）
- [rumps](https://github.com/jaredks/rumps)（メニューバーアプリ用）

---

## インストール

```bash
# 1. リポジトリをクローン
git clone https://github.com/YOUR_USERNAME/claude-usage-display.git
cd claude-usage-display

# 2. rumps をインストール
pip3 install rumps --break-system-packages

# 3. セットアップ実行
bash install.sh
```

`install.sh` が以下をすべて自動で設定します：

- CLIステータスバーの登録（`~/.claude/settings.json`）
- メニューバーアプリのログイン時自動起動（LaunchAgent）
- ログイン時にTerminalで `claude` を自動起動（LaunchAgent）

---

## 使い方

インストール後、**再ログイン**（または再起動）すると：

1. Terminalが自動で開き `claude` CLIが起動
2. CLIで会話するとステータスバーに `📊 28% ⏱ 4h18m でリセット` と表示される
3. メニューバーにも `📊 28% ⏱4h18m` と表示される

### メニューバーの表示パターン

| 状況 | 表示 |
|---|---|
| CLI使用から5分以内 | `📊 28% ⏱4h30m` |
| CLIを使っていない | `📊 28% (2時間前)` |
| データなし（初回） | `📊 ?` |

---

## ファイル構成

```
claude-usage-display/
├── claude_usage.sh          # CLIステータスバー用スクリプト
├── menubar_app.py           # macOSメニューバーアプリ
├── start_claude.command     # ログイン時Terminal起動スクリプト
├── install.sh               # セットアップスクリプト
└── tests/                   # テスト
```

---

## 仕組み

Claude Code CLIは `statusLine` スクリプト実行時に **stdin** でレート制限データを渡します：

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

`claude_usage.sh` がこのデータを受け取り、`~/.claude/claude_usage_cache.json` にキャッシュ。メニューバーアプリがそのキャッシュを30秒ごとに読んで表示します。

> **注意：** データはCLI（`claude`コマンド）経由でのみ更新されます。Claude for Desktop単独では更新されないため、本ツールはCLIを常時起動しておく運用を前提としています。

---

## アンインストール

```bash
# LaunchAgent を停止・削除
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.claude-usage.menubar.plist 2>/dev/null
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.claude-usage.cli-terminal.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.claude-usage.menubar.plist
rm -f ~/Library/LaunchAgents/com.claude-usage.cli-terminal.plist

# settings.json から statusLine を削除
python3 -c "
import json, pathlib
p = pathlib.Path.home() / '.claude/settings.json'
d = json.loads(p.read_text())
d.pop('statusLine', None)
p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + '\n')
print('statusLine を削除しました')
"
```

---

## ライセンス

MIT
