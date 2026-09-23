# zsh-smart-complete

> Zsh 向けのモダンなスマート補完・候補提示レイヤー。
> 将来の独立シェルのフロントエンドとして設計。
>
> **v2.2.11** — `~/.zshrc` を触らずに調整でき、パスポップアップが autocomplete 相当に。インストーラーはプラグインの隣に小さな `zsc-settings` CLI（wizard / list / get / set / edit / reset / path / init、いずれも型検証付き）を置き、プラグインが既定値より前に読む上書きファイルを書きます。ライブポップアップもパスについては autocomplete 風に：最初のセグメント文字から一覧（`/u`、`~/l`、`cd /usr/`）、裸の `/` はその場でディレクトリを一覧、単一マッチもインライン灰字の隣に 1 行ポップアップを描画します。パス以外の単語は 2 文字の閾値のまま。`SMART_MENU_MIN_MATCHES=2` で元に戻ります。

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-TW.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md)

## ステータス

| チャンネル | ステータス |
| ------ | ------ |
| ビルドとテスト (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| リリース | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| バージョン | 2.2.11 |

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
curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh | bash
```
対話プロンプトは `/dev/tty` から読むため、stdin がスクリプト本体でもメニューは入力を待ちます。

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

インストーラは外部 IP の帰属を自動検出して表示します。帰属が決めるのは**どの候補を出すか**です: 中国大陸 / 検出失敗なら全候補を表示して全候補（**direct を含む**）を速度測定します（direct が本当に速いかは地域から推測せず実測すべきだからです）。**中国大陸以外ではプリセットミラーをすべて隠し** direct だけを残します——それらの ghproxy / gitclone 経路は中国大陸専用で、この地域では直連より遅くなりがちです。ただし中国大陸以外でも **direct は従来どおり速度測定**し、2 つの手動入力も常に残ります:**ミラー源**（GitHub の URL を書き換える）と**フルプロキシ**（`HTTP_PROXY`/`HTTPS_PROXY` としてエクスポートし、curl/git/wget の全リクエストを通す。例: `http://127.0.0.1:7890`）です。プリセットのミラーは「中国大陸向け」と明記されています。以下のコマンドは非対話インストール時のみ必要です。

```zsh
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh | SMART_INSTALL_GH_MIRROR=https://ghproxy.net/ bash
```

## 設定

プラグインの読み込み**前**に以下の変数を設定します：

```zsh
# マスタースイッチ
: ${SMART_ENABLED:=true}
# エンジン
: ${SMART_SUGGEST:=true}
: ${SMART_COMPLETE:=true}
: ${SMART_SUGGEST_STRATEGY:=history,completion}  # history,completion | history（既定の組み合わせ: 履歴にない場合も補完が提案を埋める）
# 履歴バックエンド：zsh | atuin | smart-engine（将来）
: ${SMART_HISTORY_BACKEND:=zsh}
# UI
: ${SMART_INLINE:=true}
: ${SMART_SUGGEST_COLOR:=auto}       # auto = 256色端末は fg=110、それ以外は fg=8

# 入力でポップアップする候補リスト（zsh-autocomplete 側）
: ${SMART_MENU:=true}
: ${SMART_MENU_MIN_PREFIX_CMD:=2}     # コマンド語をリスト表示する最小文字数
: ${SMART_MENU_MIN_PREFIX:=2}         # 引数語をリスト表示する最小文字数（最後の "/" 以降を
                                      # カウント、0 = 空白直後も表示）
: ${SMART_MENU_MIN_MATCHES:=1}        # ポップアップを描く最少候補数（1 = 単一マッチも表示、autocomplete 相当）
: ${SMART_MENU_MAX_MATCHES:=100}       # これより多い候補はリスト非表示（巨大ディレクトリと zsh の「N 個すべて表示?」を回避）
: ${SMART_MENU_MAX_PREFIX:=64}
: ${SMART_MENU_HISTORY_KEYS:=false}  # true = 行が空でないとき ↑/↓ で履歴を前方一致検索
: ${SMART_MENU_SINGLE_COLUMN:=false} # true = 1 行 1 候補（オプトイン: 説明・色・あいまい一致は失われます）。false = zsh 標準グリッド
: ${SMART_MENU_LISTER:=builtin}       # 一覧を描くのはどちらか: builtin = 当プラグイン / fzf-tab = 描かずに外部の選択器へ
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

### 単一列ポップアップ（オプトイン）

`SMART_MENU_SINGLE_COLUMN=true` は入力中ポップアップを zsh 標準の多列グリッドではなく
**1 行 1 候補**で描画します。**既定はオフで、これは意図的です** — 有効にする前に以下を
お読みください:

- 縦並びは候補を**生成**することでのみ描画できます（compsys 自身の候補を確実に取得する方法は
  ありません: `compadd` を関数で上書きすると、一部の zsh では候補がまったく追加されなくなり
  ます — 実測）。そのためこのモードは `_main_complete` を**迂回**し、対象の文脈では候補の
  **説明**、`list-colors` の色付け、グループ化、`matcher-list` が失われます。文書化されている
  あいまい一致は、生成された候補には**適用されません**。
- 生成されるのはコマンド / 関数 / エイリアス / ビルトイン、ファイルパス、`cd` の最近
  ディレクトリのみです。それ以外（git サブコマンド、ssh ホスト、`--オプション`、`sudo …`）は
  ここでは候補がなく、ネイティブのグリッドにフォールバックするため、**入力中にポップアップの
  形が変わります** — 「2 つ目の一覧が出た」と誤解されがちです。
- 端末幅を超える候補は 1 行に切り詰められます（省略記号なし）。

仕組みは算術です。すべての*表示*文字列をちょうど `COLUMNS` 幅にパディング（または切り詰め）
するため、1 列しか入りません。入力語は glob になる前にエスケープされるため、ファイル名の
`[` でポップアップが壊れることはありません（先頭の `~/` はエスケープせず、`~/…` の候補は
そのまま動きます）。

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

### 一覧を描くのはどちらか（二者択一）

2 つの補完一覧表示器はどちらも「描く権利」を持っているため、「一覧が 2 つ同時に出る」は
どちらか一方だけでは直せません — どちらかが止まるしかありません。`SMART_MENU_LISTER` が
所有者を決めます:

| 値 | 何が起きるか |
|---|---|
| `builtin`（既定） | これまで通り、このプラグインが zsh の一覧を駆動します |
| `fzf-tab` | このプラグインは**何も描きません**。画面には外部のフローティング選択器だけが残ります |

fzf-tab を導入するわけではありません — **この**プラグインが一覧を描くのをやめることで、
あなたが入れている別の一覧表示器だけが描くようにします。インラインのグレー提案は影響を
受けません: 引き渡されるのは候補一覧だけです。`fzf-tab` では Tab ウィジェットでの
`zstyle ':completion:*' menu select` の設定もやめます。zsh の選択メニュー自体も同じ画面を
奪い合う一覧表示器だからです。

```zsh
smart-lister                       # 今はどちらが描いているか
smart-lister builtin | fzf-tab     # このシェルで切り替える
```

受け付ける綴りは次のとおりです:

| このプラグインを指す | 「引き渡す」を指す |
|---|---|
| `builtin` `smart` `internal` `native` `built-in` `on` `yes` `true` `1` | `fzf-tab` `fzf_tab` `fzf` `ftb` `external` `none` `off` `no` `false` `0` |

`off` は「**こちらの**一覧をオフ」（= 引き渡す）であり、「一覧なし」ではありません — それは
`SMART_MENU=false` です。認識できない**値**は `builtin` にフォールバックし（打ち間違いで
ポップアップが黙って消えては困る）、「認識できない」と報告します。一方 `smart-lister` に渡した
**引数**が間違っている場合は**エラーを出して非ゼロを返す**ので、`smart-lister fzf-tb` が
切り替えに成功したように見えることはもうありません。

おかしくなったら `smart-doctor` です。現在の所有者を表示し、一覧が**読み込まれていない**
ピッカーに引き渡されている場合はそれを明示し、**それを最終判定にします** — 「何も描画されない」
は「一覧が 2 つ出る」より悪い状態だからです。

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
smart-lister builtin|fzf-tab  # 一覧を描くのはどちらか（fzf-tab = 当プラグインは描かない）
smart-recent on|off|status # 最近ディレクトリ候補 + `cd ` 空語の一覧
```

## ローカル設定スクリプト

インストーラーはユーザー設定ファイルと、それを管理する小さな CLI を作成するため、`~/.zshrc` を一切変更せずにプラグインを調整できます。ファイルの場所：

```
${SMART_USER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/zsh-smart-complete/settings.zsh}
```

インストール後はいつでも `zsc-settings` を実行できます（インストーラーはこれを `~/.local/bin/zsc-settings` にシンボリックリンクするので、そのディレクトリが `PATH` に入っていることを確認するか、スクリプトをフルパスで呼び出してください）：

| コマンド | 内容 |
| --- | --- |
| `zsc-settings` | 対話ウィザード——設定を選び、新しい値を入力 |
| `zsc-settings list` | すべての設定とその有効値を表示 |
| `zsc-settings get KEY` | ある設定の有効値を表示 |
| `zsc-settings set KEY VALUE` | 値を検証して書き込む |
| `zsc-settings edit` | ファイルを `$EDITOR` で開く |
| `zsc-settings reset [KEY]` | 上書きを 1 つ（またはすべて）削除 → 既定値へ戻る |
| `zsc-settings path` | 設定ファイルのパスを表示 |
| `zsc-settings init` | コメント付き既定値でファイルを（再）作成 |

値は単なる `KEY='VALUE'` 行として書き込まれます。プラグインは内蔵の既定値より**前に**このファイルを source するため、書いた値は既定値を上書きします。値を変更した後は、**zsh を再起動**（`exec zsh` など）して反映してください。`set` は設定の型（bool / int / enum / path）に基づいて値を検証し、不正な入力を拒否します。別のファイルを使うには、zsh 起動前に `SMART_USER_CONFIG` でそのファイルを指すようにします。

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
zsh tests/test-repaint.zsh
bash tests/test-installer-options.sh
```

**テスト集計 （v2.2.11）：** 12 ファイル、804 アサーション、すべて合格、0 失敗。
インストーラーは `~/.zshrc` の清理後に、`.zprofile`、`.zshenv`、`conf.d/*.zsh`、`.zshrc.d/*`、`/etc/zsh/zshrc` の**其它の起動ファイル**に `zsh-autocomplete` / `zsh-autosuggestions` のローダー行が残っていないかも**走査**し、見つかった場合は正確な `ファイル:行番号` で**警告**して手動清理を促します——これらのファイルは編集しません。詳細は CHANGELOG の `[v2.2.5]` を参照。


主要な挙動は、tmux ペイン内の実際の `zsh -i` に対してエンドツーエンドで検証され、
描画された画面をアサートします（49/49 グリーン）。同じアサーションは v2.1.6 では
**24/49**（49 件のうち 1 件はそこでは到達しません——そのセクションは失敗後に中止されます）——当時「入力でポップアップするメニュー」は存在せず、`SS3` と `Alt+→` の
エンコーディングは死んでおり、`Tab` の後の `Enter` は飲み込まれ、最近ディレクトリは一覧
されず、一覧表示器の切り替えも単一列レイアウトもありませんでした。この 24 件の PASS のうち
**いくつかは空振り**です — 「一覧を描いていないこと」を検証していますが、v2.1.6 は一覧をまったく
描きません。ベースラインを古い数字から按分できないのはそのためです。
このハーネスはリポジトリに同梱されています（`tmux` がなくても自動スキップ）：

```zsh
./tests/e2e-tmux.sh                              # 49 アサーション
./tests/e2e-tmux.sh /tmp/zsc-v216               # 旧リリースとの A/B
```

e2e はさらに「バッファ完全性」も検証します。1 文字ずつ入力した結果の
プロンプト行が入力内容と完全に一致し、さらに**実際に実行されたコマンド**の出力で
交差検証します。リストを描画するたびにキーを 1 つ飲み込む静かな不具合は、
「画面を見るだけ」の検査をすべて通り抜けてしまうからです。

手法は `headless-pty-zle-verify` スキルにまとめられています。

`tests/test-repaint.zsh` は、tmux ハーネスが**構造的に見られない**部分を担当します:
zsh が 1 キーストロークごとに端末へ書き出す実際のバイト数です。tmux は「改行 + カーソル
アップ」の組を打ち消すため、プラグインが毎回スクロールを伴う再描画を行っても、画面**も**
スクロールバック**も**同一になります。このテストは `zsh/zpty` 経由で実際の `zsh -i` を
駆動し、生のバイト列を読み、ただ 1 つの不変条件を検証します: **1 キーストロークは 1 行に
留まる** — 改行なし、垂直方向のカーソル移動なし、画面消去なし。2 行プロンプトでの実測:

| ビルド | バイト数 | スクロールを伴う改行 |
| --- | --- | --- |
| 毎キーで再描画 | 96 | あり — しかもゴースト**と**ポップアップを両方切っても 32 バイト (素の zsh は 1) |
| 本リリース | 33 | なし — 両方切ると 1 バイト、素の zsh と完全に一致 |

旧ビルドでは失敗し本ビルドでは成功するため、将来この再描画を復活させる「修正」は
ユーザーではなく CI が先に検出します。CHANGELOG `[v2.2.10]` を参照。

## ライセンス

MIT — [LICENSE](./LICENSE) を参照。
