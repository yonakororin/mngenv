# phpenv + PHP-FPM + nginx セットアップ TUI

ディレクトリごとに異なる PHP バージョンを使い分ける開発環境を、
対話的な TUI (テキストユーザーインターフェース) で構築するスクリプトです。

## クイックスタート

```bash
bash setup.sh
```

以下のような操作画面が表示されます。

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  phpenv + PHP-FPM + nginx セットアップ                                     ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ PHPENV_ROOT: /home/user/.phpenv    nginx port: 8080                        ║
╠══════════════════════════════════════════════════════════════════════════════╣
║   フォルダパス                     PHPバージョン   サブドメイン名           ║
║   ────────────────────────────── ────────────── ────────────────────        ║
║  [/home/user/projects/my-app   ] 8.3.8          my-app                     ║
║   /home/user/projects/legacy     7.4.33         legacy                     ║
║   /home/user/projects/api        8.4.19         api                        ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  ↑↓←→ 移動  Enter 編集  a 追加  d 削除  p ポート変更                       ║
║  F5/r PHPENV_ROOT変更  F10/x 実行  q/ESC 終了                              ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

## 操作方法

| キー | 操作 |
|------|------|
| `↑` `↓` | 行を選択 |
| `←` `→` | 列を選択 (フォルダパス / PHPバージョン / サブドメイン名) |
| `Enter` | 選択中のセルを編集 (インライン編集、←→でカーソル移動) |
| `a` | プロジェクト行を追加 |
| `d` | 選択中の行を削除 |
| `p` | nginx の listen ポートを変更 (デフォルト: 8080) |
| `r` / `F5` | PHPENV_ROOT を変更 |
| `x` / `F10` | 設定を確定してセットアップ実行 |
| `q` / `ESC` | 中止 |

### セル編集中の操作

| キー | 操作 |
|------|------|
| `←` `→` | カーソル移動 |
| `Home` | 先頭へ |
| `End` | 末尾へ |
| `Delete` | カーソル位置の文字を削除 |
| `Backspace` | 前の文字を削除 |
| `Enter` | 確定 |
| `ESC` | キャンセル (元の値に戻る) |

## 各フィールドの説明

| フィールド | 説明 | 例 |
|------------|------|-----|
| フォルダパス | プロジェクトのルートディレクトリ。`webroot/` があればそこがドキュメントルートになる | `/home/user/projects/my-app` |
| PHPバージョン | X.Y.Z 形式のフルバージョン | `8.3.8`, `7.4.33`, `8.4.19` |
| サブドメイン名 | nginx の server_name に使われる (`.localhost` が自動付与される) | `my-app` → `my-app.localhost` |

## セットアップ実行時の処理

`x` または `F10` で実行すると、以下が順番に行われます。

1. **ディストリビューション検出** — apt / dnf / pacman 等を自動判別
2. **phpenv / php-build インストール** — 未導入なら自動
3. **ビルド依存パッケージ** — ディストリ別に適切なパッケージをインストール
4. **nginx インストール** — 未導入なら自動
5. **PHP ビルド** — 一覧にあるバージョンのうち、未ビルドのものをビルド (重複スキップ)
6. **php-fpm 設定 + サービス起動** — バージョンごとに専用ポートで起動
7. **プロジェクト設定** — `.php-version` 配置、`webroot/` 作成
8. **nginx vhost 設定** — サブドメイン名.localhost で vhost 生成、リロード
9. **CLI ラッパー** — `~/.local/bin/php`, `composer` をインストール

### PHP バージョンの切り替え

同じフォルダの PHP バージョンを変更して再実行すると、`.php-version` と nginx の fastcgi_pass が自動更新されます。

### サブドメイン名の変更

サブドメイン名を変更すると、旧ホスト名の nginx 設定が自動削除されます。

## CLI バージョン切替の仕組み

`~/.local/bin/php` ラッパーがカレントディレクトリから上方向に `.php-version` を探索し、
対応する phpenv のバイナリを直接実行します。

```
$ cd ~/projects/my-app && php -v    → PHP 8.3.8
$ cd ~/projects/legacy && php -v    → PHP 7.4.33
```

cron やシェルスクリプト内でも動作します。

```cron
PATH=/home/user/.local/bin:/usr/local/bin:/usr/bin:/bin
0 5 * * *  cd ~/projects/my-app && php batch/job.php
```

## 設定ファイル

TUI で編集した内容は `setup.sh` と同じディレクトリの `.setup-projects.conf` に保存されます。
次回実行時に自動で読み込まれるため、前回の設定が引き継がれます。

```
# .setup-projects.conf
# フォルダパス|PHPバージョン|サブドメイン名
/home/user/projects/my-app|8.3.8|my-app
/home/user/projects/legacy|7.4.33|legacy
/home/user/projects/api|8.4.19|api
```

## FPM ポート割り当て

| PHPバージョン | FPM ポート | サービス名 |
|--------------|-----------|-----------|
| 7.4.x | 9074 | php-fpm-74 |
| 8.2.x | 9082 | php-fpm-82 |
| 8.3.x | 9083 | php-fpm-83 |
| 8.4.x | 9084 | php-fpm-84 |

## 運用コマンド

```bash
# FPM 状態一覧
phpenv-fpm-status

# 個別サービス操作
systemctl --user status php-fpm-83
systemctl --user restart php-fpm-83

# PHP バージョン確認
phpenv versions

# ビルド可能なバージョン確認
phpenv install --list
```

## 対応環境

| 項目 | 要件 |
|------|------|
| OS | Debian / Ubuntu / RHEL / CentOS / Rocky / Alma / Fedora / Arch / openSUSE / Alpine |
| init system | systemd または OpenRC |
| シェル | bash (zsh も .zshrc を自動検出) |
| 権限 | sudo (パッケージ, nginx 設定) |
| ディスク | PHP 1バージョンあたり約 100-200 MB |

## トラブルシューティング

### Definition not found

php-build の定義が古い場合、自動で `git pull` → 定義ファイル自動生成を行います。
それでも失敗する場合は手動更新してください。

```bash
cd ~/.phpenv/plugins/php-build && git pull
```

### ポート競合 (WSL 環境)

WSL では Windows 側のプロセスがポート 80 を使用していることがあります。
TUI の `p` キーでポートを変更してください (デフォルト: 8080)。

### php -v でバージョンが切り替わらない

```bash
which php  # ~/.local/bin/php であること
source ~/.bashrc
```
