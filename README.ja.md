# zsh-smart-complete

> Zsh 向けのモダンなスマート補完・候補提示レイヤー。
> 将来の独立シェルのフロントエンドとして設計。
>
> **v2.2.3** — 最新リリース：入力中ポップアップが**単一列**（1 行 1 候補、グリッドではない）に。`Delete` が残像を残さなくなり、`smart-doctor` が「2 つ目の候補一覧」の指紋をすべて出力します。インストーラはオプション（fzf-tab / 単一列 / 最近ディレクトリ / 履歴キー / vi-mode）を 1 つずつ質問し、回答を `~/.zshrc` に書き込みます。

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-TW.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md)

## ステータス

| チャンネル | ステータス |
| ------ | ------ |
| ビルドとテスト (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| リリース | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| バージョン | 2.2.3 |

## なぜこれを選ぶか

`zsh-autocomplete` と `zsh-autosuggestions` の両方を、清潔なモジュール構成の単一プラグインで置き換え、将来の独立シェルへ進化するように設計しています。

- **二つの半身、一つのエンジン（v2.2.0）** — 入力中に候補リストが**即座にポップアップ**します（zsh-autocomplete の挙動）と同時に、行内の灰色サジェストは残ります。`→` は全体を受け入れ、`Alt+→` は単語一つを受け入れます（zsh-autosuggestions の挙動）。一つのプラグイン、一つのキーマップ、二つのチャンネル——これが「二つのプラグインが衝突する」根本的な解決策です。
- **外部依存ゼロ** — コアプラグインは自己完結、Atuin はオプション。
- **矢印キーの全エンコーディングをバインド** — `ESC [ C` と `ESC O C`（アプリケーションカーソルキーモード、`TERM=xterm-256color` で端末が実際に送る形式）の両方をバインドしているため、「灰色文字は出るのに矢印が効かない」は起きません。
- **シンタックスハイライトと共存** — `#zsh-smart-complete:suggestion` タグを使用し、他のハイライターを上書きしません。

## アーキテクチャ

```
              zsh-smart-complete.plugin.zsh
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
      config            state             event/zle
         │                 │                 │
         └─────────────────┼─────────────────┘
                           │
               ┌───────────┴───────────┐
               │                       │
         engine/suggest          engine/native
               │                       │
        history/history         (ユーザーの compinit)
                                       │
                                   engine/menu
                              （入力でポップアップするリスト）
               │
      zsh fc   │   atuin (任意)   │   smart-engine (将来)
               └───────────────────┴───────────────────┘
                           │
                     display/
                 region_highlight
```

## クイックスタート

### 前提条件

Zsh 自身が `compinit` を持つようにします：

```zsh
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=1000000
export SAVEHIST=1000000
setopt appendhistory sharehistory histignorealldups

autoload -Uz compinit
compinit
```

### インストール

> ⚠️ このプラグインは `zsh-autocomplete` と `zsh-autosuggestions` の**両方**を置き換えます。

#### 方式 A — ワンラインインストーラー（推奨）

```zsh
bash <(curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)
```

#### 方式 B — Zinit

```zsh
zinit light imonior/zsh-smart-complete
```

#### 方式 C — 手動クローン

```zsh
git clone https://github.com/imonior/zsh-smart-complete.git ~/.zsh-smart-complete
echo 'source ~/.zsh-smart-complete/zsh-smart-complete.plugin.zsh' >> ~/.zshrc
```

#### 中国国内向けミラー

```zsh
SMART_INSTALL_GH_MIRROR=https://ghproxy.net/ bash -c "$(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)"
```

## 設定

プラグインの読み込み**前**に以下の変数を設定します：

```zsh
# マスタースイッチ
: ${SMART_ENABLED:=true}
# エンジン
: ${SMART_SUGGEST:=true}
: ${SMART_COMPLETE:=true}
: ${SMART_SUGGEST_STRATEGY:=history}  # history | history,completion（completion は補完システムも提案元にする）
# 履歴バックエンド：zsh | atuin | smart-engine（将来）
: ${SMART_HISTORY_BACKEND:=zsh}
# UI
: ${SMART_INLINE:=true}
: ${SMART_SUGGEST_COLOR:=fg=8}

# 入力でポップアップする候補リスト（zsh-autocomplete 側）
: ${SMART_MENU:=true}
: ${SMART_MENU_MIN_PREFIX_CMD:=2}     # コマンド語をリスト表示する最小文字数
: ${SMART_MENU_MIN_PREFIX:=1}         # 引数語をリスト表示する最小文字数（0 = 空白直後も表示）
: ${SMART_MENU_MIN_MATCHES:=2}        # これ未満の候補数ならリスト非表示（単一候補は灰色文字が担う）
: ${SMART_MENU_MAX_MATCHES:=100}       # これより多い候補はリスト非表示（巨大ディレクトリと zsh の「N 個すべて表示?」を回避）
: ${SMART_MENU_MAX_PREFIX:=64}
: ${SMART_MENU_HISTORY_KEYS:=false}  # true = 行が空でないとき ↑/↓ で履歴を前方一致検索
: ${SMART_MENU_SINGLE_COLUMN:=true}  # true = 1 行 1 候補（単一列）。false = zsh 標準のグリッド
# スロットル：既定でオフ。実測ではリスト取得はわずか 10~30ms で絞る意味がなく、
# この設定は「継続的に高負荷な」補完のためのもの。オンの場合、SLOW_MS 以上の
# リスト取得は COOLDOWN_KEYS 回のスキップを招く。注意：スキップされたキー入力は
# 再描画されないため、その拍子に画面上のリストが消える——だから既定は 0。
: ${SMART_MENU_SLOW_MS:=250}
: ${SMART_MENU_COOLDOWN_KEYS:=0}

# デバッグ用：ファイルパスを設定すると、各 tick の決定（ゲート拒否 / クールダウン
# によるスキップ / 候補数 / 処理ミリ秒）が追記される。「ポップアップしなかった」は
# 「候補が一つで灰色文字に譲った」と見分けがつかないため、このログが役立つ。
: ${SMART_MENU_DEBUG:=}

# 最近のディレクトリ：`cd` の引数を補完するとき、実際に入ったことのある
# ディレクトリを候補に出し、`cd ` の直後の空語では即座に一覧します
# （空語を一覧する価値がある唯一の場所）。読み取り専用で、zsh 自身の
# recent-dirs データベースを消費するだけで、何も記録しません。
: ${SMART_RECENT_PATHS:=true}
: ${SMART_RECENT_PATHS_MAX:=20}
```

名前付きウィジェットも公開しているので、`zsh-autosuggestions` と同様に
キーを割り当て直せます：`smart-accept-suggestion`（候補全体を確定、既定は →）、
`smart-accept-word`（1 語だけ確定、既定は Alt+→）、
`smart-execute-suggestion`（確定してその行を実行）、
`smart-suggestion-toggle`（灰色候補の ON/OFF）。
`SMART_MENU_HISTORY_KEYS=true` にすると、行が空でないとき ↑/↓ が履歴の前方一致
検索になります（既定は無効。これらのキーの慣習が強いため）。

## 追加オプション

### あいまい一致（行うのは zsh であり、本プラグインではない）

ライブポップアップは**あなた自身の**補完システムを実行するので、設定した
matcher は自動的にそれへ適用されます。`fb` で `foobar.txt` に一致させるには：

```zsh
zstyle ':completion:*' matcher-list 'r:|[._-]=* r:|=*' 'l:|=* r:|=*'
```

ここで有効化するスイッチはありません。当側で曖昧一致を実装すると、補完
システムと衝突するだけです。

### 単一列ポップアップ

入力中ポップアップは zsh 標準の多列グリッドではなく **1 行 1 候補** で描画します。候補名が
長い場合や同じ接頭辞を共有する場合に、可読性が大きく変わります。`SMART_MENU_SINGLE_COLUMN=false`
で標準グリッドに戻せます。

候補はプラグインが直接生成し（コマンド / 関数 / エイリアス、ファイルパス、`cd ` の最近
ディレクトリ）、すべての **表示文字列** をちょうど `COLUMNS` 幅にパディングまたは切り詰めます。
これが数学的に 1 列しか入らない理由です。生成器が扱えない文脈（git サブコマンド、ssh ホスト、
オプション文字列）は **通常の補完にフォールバック** するため、失われるものはありません。

入力語は glob になる前にエスケープされるため、ファイル名の `[` でポップアップが壊れることは
ありません（先頭の `~/` はエスケープせず、`~/…` の候補はそのまま動きます）。

### 最近のディレクトリ

`cd` / `pushd` / `chdir` の引数を補完するとき、実際に入ったことのある
ディレクトリが候補として提示され、さらに `cd ` 直後の**空語**で即座に一覧
されます（空語を一覧する価値がある唯一の場所）。

データは zsh 自身の recent-dirs データベース——`cdr` や `~[1]` と同じものです。
プラグインは**読むだけ**で、書き込みは一切しません。まだ空の場合は、次の
2 行で記録を有効にできます：

```zsh
autoload -Uz chpwd_recent_dirs add-zsh-hook
add-zsh-hook chpwd chpwd_recent_dirs
```

`smart-recent status` で現在いくつ使えるかを確認できます。

### 候補一覧が 2 つ同時に出る？

画面に一覧が 2 つ同時に現れる場合、`smart-doctor` が既知の「一覧表示器」すべての指紋を
出力します。議論ではなく、読んで判断できる形になります:

```zsh
smart-doctor
```

`_main_complete` / `compadd` / `_complete` が zsh 標準の入口のままか、
`zsh-autocomplete` / `zsh-autosuggestions` / `fzf-tab` / シンタックスハイライトが読み込まれて
いるか、キーマップごとに `Tab` を誰が持つか、一覧を有効にし得る zstyle、そしてこの
プラグイン自身の状態を報告し、最後に判定を 1 行出します。**読み取り専用** なので、壊れかけの
shell でも安全に実行できます。

### インストーラのオプション（対話式）

インストーラは fzf-tab、単一列レイアウト、最近ディレクトリ、↑/↓ 履歴検索、zsh-vi-mode、
候補の取得元を 1 つずつ質問し、回答を `~/.zshrc` の管理ブロックへ書き込みます。このブロックは
意図的に **プラグイン読み込みより前** に置きます。`SMART_MENU_HISTORY_KEYS` のような
オプションは、プラグインがキーバインドを設定する **時点** で読まれるため、後から書いても
黙って無視されるからです。再実行するとそのブロックだけが書き換わります。
`NONINTERACTIVE=1` では文書化された既定値になります。

fzf-tab は既定で **オフ**（明示的なオプトイン）です。有効にすると組み込みの選択メニューを
強制的にオフにします — どちらも補完の **一覧表示器** であり、両方を同時に有効にすることが
2 つのポップアップが同じ画面領域を奪い合う原因そのものです。

## 実行時コマンド

```zsh
smart-status      # 現在の状態 + 設定を表示
smart-disable     # プラグインを無効化
smart-enable      # 再有効化
smart-reindex     # 履歴インデックスを強制再構築
smart-menu on     # 入力でポップアップするリストをオン
smart-menu off    # オフ（行内灰色サジェストは影響なし）
smart-menu status # メニュー設定と直前のリスト結果を表示
smart-doctor      # 「2 つ目の候補一覧」の指紋をすべて表示（他に誰が一覧を描いているか）
smart-recent on|off|status # 最近ディレクトリ候補 + `cd ` 空語の一覧
```

## アンインストール

```zsh
rm -rf ~/.zsh-smart-complete
```

## チェンジログ

全文は [CHANGELOG](./CHANGELOG.ja.md) を参照してください。GitHub のリリースノートは、これらの多言語 CHANGELOG ファイル（en / zh-CN / zh-TW / ja / ko）から抽出されます。

## テスト

```zsh
zsh tests/test-config.zsh
zsh tests/test-history.zsh
zsh tests/test-suggest.zsh
zsh tests/test-ranking.zsh
zsh tests/test-atuin.zsh
zsh tests/test-zle.zsh
zsh tests/test-menu.zsh
zsh tests/test-integration.zsh
zsh tests/test-recent.zsh
bash tests/test-installer-options.sh
```

**テスト集計 (v2.2.3)：** 10 ファイル、538 アサーション、すべて合格、0 失敗。

主要な挙動は、tmux ペイン内の実際の `zsh -i` に対してエンドツーエンドで検証され、
描画された画面をアサートします（33/33 グリーン）。同じアサーションは v2.1.6 では
**18/33**——当時「入力でポップアップするメニュー」は存在せず、`SS3` と `Alt+→` の
エンコーディングは死んでおり、`Tab` の後の `Enter` は飲み込まれ、最近ディレクトリは一覧
されず、単一列レイアウトもありませんでした。
このハーネスはリポジトリに同梱されています（`tmux` がなくても自動スキップ）：

```zsh
./tests/e2e-tmux.sh                              # 33 アサーション
./tests/e2e-tmux.sh /tmp/zsc-v216               # 旧リリースとの A/B
```

e2e はさらに「バッファ完全性」も検証します。1 文字ずつ入力した結果の
プロンプト行が入力内容と完全に一致し、さらに**実際に実行されたコマンド**の出力で
交差検証します。リストを描画するたびにキーを 1 つ飲み込む静かな不具合は、
「画面を見るだけ」の検査をすべて通り抜けてしまうからです。

手法は `headless-pty-zle-verify` スキルにまとめられています。

## ライセンス

MIT — [LICENSE](./LICENSE) を参照。
