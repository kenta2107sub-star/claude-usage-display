# claude-usage-display

Claude Code の5時間レート制限の使用量を **CLIステータスバー** と **macOSメニューバー** に表示するツールです。

![CLI statusLine example](https://img.shields.io/badge/📊%2028%25%20⏱4h30m-green)

---

## 機能

- **CLIステータスバー** — `claude` コマンド使用中、入力欄の下に使用率とリセット時刻をリアルタイム表示
- **macOSメニューバーアプリ** — Claude for Desktop 使用中もメニューバーに常時表示。更新時刻を常に併記
- **バックグラウンドポーリング** — 15分ごとに自動更新。CLIを起動しなくてもメニューバーが最新値を保つ
- **ログイン時自動起動** — PC起動時にTerminalで `claude` CLIを自動起動

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
git clone https://github.com/kenta2107sub-star/claude-usage-display.git
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
- 15分ごとのバックグラウンドポーリング（LaunchAgent）

---

## 使い方

インストール後、**再ログイン**（または再起動）すると：

1. Terminalが自動で開き `claude` CLIが起動
2. CLIで会話するとステータスバーに `📊 28% ⏱ 4h18m でリセット` と表示される
3. メニューバーに `📊 28% (1分前) ⏱4h18m` と表示される
4. Claude for Desktop のみ使用中でも15分ごとに自動更新される

### メニューバーの表示パターン

| 状況 | 表示 |
|---|---|
| データあり（通常） | `📊 28% (2分前) ⏱4h30m` |
| リセット済み | `📊 0% (5分前)` |
| データなし（初回） | `📊 ?` |

`(X分前)` は `used_percentage` の最終更新時刻を示します。ポーラーが15分ごとに更新するため、最大15分の遅延が生じます。

---

## ファイル構成

```
claude-usage-display/
├── claude_usage.sh          # CLIステータスバー用スクリプト
├── menubar_app.py           # macOSメニューバーアプリ
├── rate_limit_poller.sh     # 15分ごとバックグラウンドポーリング
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

### Claude for Desktop 対応（バックグラウンドポーリング）

`rate_limit_poller.sh` が15分ごとに Python `pty` モジュールで仮想TTYを作り、バックグラウンドで `claude` インタラクティブセッションを起動して `used_percentage` を取得します。ターミナルウィンドウは開きません。

- CLI または Claude for Desktop のいずれかが**30分以内に活動していれば**実行
- 両方とも30分以上アイドルな場合はスキップ（不要なトークン消費を抑制）
- ポーラーのAPI呼び出しはトークンを消費しますが、Pro/Maxプランでは追加課金なし

---

## アンインストール

```bash
# LaunchAgent を停止・削除
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.claude-usage.menubar.plist 2>/dev/null
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.claude-usage.cli-terminal.plist 2>/dev/null
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.claude-usage.rate-limit-poller.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.claude-usage.menubar.plist
rm -f ~/Library/LaunchAgents/com.claude-usage.cli-terminal.plist
rm -f ~/Library/LaunchAgents/com.claude-usage.rate-limit-poller.plist

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
