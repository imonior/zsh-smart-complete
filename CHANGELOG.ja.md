# チェンジログ

このプロジェクトのすべての重要な変更はこのファイルに記録されます。

フォーマットは [Keep a Changelog](https://keepachangelog.com/) に基づき、このプロジェクトは
[セマンティックバージョニング](https://semver.org/lang/ja/) に準拠します。

## [v2.2.0] - 2026-09-15

このプラグインが存在する**全理由**をついに実現したリリース：`zsh-autocomplete` +
`zsh-autosuggestions` の二つの半身を、単一プラグインの中でネイティブに提供します。

### Added
- **入力でポップアップする候補メニュー**（`lib/engine/menu.zsh`）：バッファを編集するたびに
  候補リストを計算・描画するため、補完は入力中に表示されます——`Tab` は不要。ユーザー自身の
  compsys 上に、プライベートな補完ウィジェット（`zle -C ... list-choices`）を使って実装。その
  completer は `compstate[nmatches]` を読み、リストを描画するか決定します。`compinit` には
  一切触れません。マスタースイッチは `SMART_MENU`、実行時は `smart-menu on|off|status`。
- **行内灰色サジェストと候補リストが共存。** リスト再描画と `POSTDISPLAY` は同じ画面領域を争う
  ため、順序を固定しました：先に灰色文字を描画し、その後にリストを実行、その後は再描画しません。
  単一の候補（`SMART_MENU_MIN_MATCHES`）はリストを破棄し、灰色文字に譲ります。
- **適応型スロットル**（`SMART_MENU_SLOW_MS` / `SMART_MENU_COOLDOWN_KEYS`、既定オフ）：閾値以上に
  時間がかかるリスト取得はクールダウンを招き、**継続的に**高負荷な補完のためのもの。既定オフの
  理由は、実測で唯一の尖峰が補完サブシステム読み込み時の一回限り ~180ms であり、それを絞ると
  セッション最初の `git <TAB>` でポップアップを失うだけで、節約はその一度の 180ms だからです。
- **`SMART_MENU_DEBUG=/path/to/log`**：各 tick の決定（ゲート拒否 / クールダウンによるスキップ /
  候補数 / 処理ミリ秒）を1行追記します。「ポップアップしなかった」は「候補が一つで灰色文字に譲った」
  と見分けがつかないため、このログが役立ちます。
- **`Alt+→` で単語一つを受け入れ**：行内サジェストの単語一つを受け入れ（その後残りを再サジェスト）。
  受け入れるものがないときは標準の `forward-word` にフォールバックします。

### Fixed
- **重大 — 新規セッションで右矢印が効かない**：`ESC [ C`（CSI）しかバインドしておらず、
  `TERM=xterm-256color` の `kcuf1` は `ESC O C`（*アプリケーションカーソルキー* 形式）であり、
  ZLE は端末をそのモードに切り替えるため。そのキーは zsh 標準の `forward-char` に渡り、サジェストは
  決して受け入れられず、灰色文字だけが表示される——典型的な「灰色文字は出るのに矢印が死んでいる」
  報告。すべての矢印エンコーディングをバインドし、シーケンス一覧は `terminfo` に CSI/SS3 の
  フォールバックを加えて構築します。
- **重大 — 同じ端末で `Alt+→` も死**：`Alt` は文字通り「`ESC` を送り、その後に矢印」なので、多重
  エンコーディング問題を継承します。旧版は `ESC [ 1 ; 3 C`（xterm）と `ESC ESC [ C` しかバインド
  しておらず、アプリケーションカーソルキーモードの端末が送る `ESC ESC O C` は未バインドで、リテラル
  な `^[` をバッファに落としていました。`Alt` 形式は今後「各矢印エンコーディングに `ESC` を前置」して
  **派生**させるため、二つが再び乖離することはありません。
- **バインド捕獲が生バイト列を誤解析**：`_smart_evt_binding`（`lib/event/zle.zsh`）と
  `_smart_current_binding`（`lib/engine/native.zsh`）は照会したシーケンスをテキスト一致で剥ごうと
  していましたが、`bindkey` はキーを常に `^X` 記法でエコーするため、生バイト列（例：terminfo の
  `kcuf1`）では一致に失敗し、*キー文字列*がウィジェット名として格納されていました。保存された原本が
  汚染され、アンバインド時にキーが二度と復元されませんでした。両パーサは今後 `bindkey` 出力の末尾
  フィールドを取ります。
- **ループ内の `local` が stdout に漏れる**（`lib/event/zle.zsh`）：zsh 5.9 は `local` 宣言を2回目
  以降に実行すると `var='<旧値>'` を印字し、これは2回以上反復するループ内に書かれた `local` で
  発生します。その出力は ZLE ウィジェット経路でそのままコマンドラインに届きます。すべてのループ変数を
  関数先頭で一度だけ宣言するようにし、`tests/test-zle.zsh` で bind/unbind サイクルの無音を
  アサートします。
- **`zmodload -F` の機能プレフィックス**：`EPOCHREALTIME` と `terminfo` は*パラメータ*なので
  `p:EPOCHREALTIME` / `p:terminfo` として要求する必要があります。拒否された `b:` 要求により両方が
  未定義のままとなり、スロットルと terminfo 由来の矢印シーケンスが静かに無効化されていました。回帰
  テストを追加。
- **連想配列の引用下付き**：`assoc["km|seq"]=x` は引用符をキー名の一部として格納するため、
  `assoc[km|seq]` では到達できません。キーは今後変数で組み立て、引用なし下付きで索引します
  （`lib/state.zsh` が既に守っていた規則と同じ）。
- **インストーラ**：*なぜ* `zsh-autocomplete` / `zsh-autosuggestions` を削除するか（両方の挙動は
  今やネイティブ）を説明するようになり、黙って削除しなくなりました。

## [v2.1.6] - 2026-09-15

### Fixed
- **重大 — 印字可能 ASCII 入力が飲み込まれる**：`_smart_evt_binding` が `bindkey -R "^@-^_"`
  範囲クエリから疑似ウィジェット `undefined-key` を捕獲し、印字可能キーをそこにディスパッチしたため、
  `zle undefined-key`（無操作）がすべての ASCII キー入力を食っていました。CJK/UTF-8（バイト >= 0x80、
  再バインド範囲外）は本来の `self-insert` から挿入され続けたため、「中国語は入るが英語が入らない」。
  捕獲は今後 `undefined-key` を未バインドに正規化して `self-insert` を使い、`_smart_evt_dispatch` も
  それを守り、`_smart_current_binding`（native.zsh）も同様に強化。`tests/test-zle.zsh` に回帰
  テストを追加。
- **キー捕獲の強化**：self-insert の原本ウィジェットは今後範囲プローブではなくハードコードします
  （範囲クエリは当社のバインド前は `undefined-key`、バインド後は当社の wrapper を返し、どちらも使える
  原本ではない）。捕獲は専用フラグ `_SMART_EVT_CAPTURED` で守り、単一の `ORIG_*` 変数の内容ではなく
  したため、古い・手動設定の `_SMART_EVT_ORIG_SELF_*` が全体捕獲をスキップ（それは静かにネイティブな
  Tab バインドや他の原本も落とす）することはなくなりました。捕獲プローブはさらに、いかなる `_smart_*` /
  `smart-*` ウィジェットの記録も拒否し、再捕獲が自らの wrapper にディスパッチし直すことはなくなりました。
- **インストーラ — 管理ブロックのマーカが書かれなかった**：`build_zsc_integration` が bash スクリプト
  内で `print -r --`（zsh 組込み）を使っていたため呼び出しは静かに失敗し、`# >>> zsh-smart-complete
  integration (managed) >>>` / `# <<< ... <<<` マーカ行が落とされていました。BEGIN マーカがないと
  `_upsert_zsc_block` は一致できず、再インストールのたびに重複ブロックを追加していました。今後は
  `printf '%s\n'` を使用。

### Added
- **任意の `zsh-vi-mode`（opt-in、既定 NO）**：vi キーバインドは確かに有用ですが、本プラグインは
  キーマップ全体を所有し、各行初期化で ZLE を再初期化するため、他プラグインのバインドを壊す典型的原因
  です——ゆえに暗黙にインストールすることはありません。選択時、インストーラはそれをクローンし、当社の
  ウィジェットを *前* に読み込み、`zvm_after_init` / `zvm_after_lazy_keybindings` 経由で再適用する
  ブロックを書きます。
- **インストーラがフロー内で fast-syntax-highlighting をインストール**（`_ensure_zinit_plugin
  zdharma-continuum/fast-syntax-highlighting`）、フルコンボとプラグイン両経路で、Zinit の初回起動
  自動クローンに依存しなくなりました。

### Changed
- **インストーラの .zshrc 戦略**：完全推奨 `.zshrc` テンプレートは、今回フルスタックを（再）インストール
  した場合（Phase 0/5 コンボ）のみ推奨。プラグインのみのインストールは今後、マーカ区切りの
  `zsh-smart-complete` ブロックのみを管理（べき等 upsert、ファイル全体を上書きしない）。

## [v2.1.5] - 2026-09-15

### Fixed
- **インストーラ — p10k/OMZ 除去器**：`_remove_p10k` / `_remove_omz` は今後 Zinit クローン済み
  プラグイン dir（`$ZINIT_PLUGINS_DIR` 下の `romkatzen---powerlevel10k`、`OMZ::ohmyzsh---ohmyzsh`）
  も削除するため、非 p10k/OMZ コンボを選ぶと次回起動で再読み込みされる古い残骸を完全に消去します。
  `.bak.*` 成果物はカスケードバックアップを避けるため直接削除。
- **インストーラ — `.zwc` バイトコード**：プラグイン更新経路（`git reset --hard`）は今後 Zinit コンパイル
  済み `*.zwc` キャッシュも削除するため、エンジン修正が更新後に実際に効く（以前は古いコンパイル済み
  コードが読み込まれていた）。
- **エンジン — グローバル漏洩**：`lib/engine/suggest.zsh` の `cmd_cwd` / `cmd_host` / `cmd_exit` は
  今後 `local` 宣言（以前は毎キー入力でグローバルに漏れていた）。
- **エンジン — 履歴上限**：`_SMART_CMDS` は今後 `SMART_SUGGEST_HISTORY_LIMIT`（既定 20000）に制限。
  `SMART_HISTORY_REBUILD_EVERY=0` で周期再構築を無効にした場合、最古エントリを破棄し bucket/assoc
  スロットを同期したままに。

## [v2.1.4] - 2026-09-12

### Fixed
- fzf インストールが静かにスキップされていた（非対話）。インストール進捗が2回表示（Phase 0/5 のち
  Phase 1-4）。`RAN_COMBO` ガードを追加し fzf プロンプトを対話式に。

## [v2.1.3] - 2026-09-11

### Fixed
- すべての y/N プロンプトで `read: -: invalid option` クラッシュ——`IFS=$'\n\t'` が `read $_args` を
  壊していた。 `read "$@"` に変更。

## [v2.1.2] - 2026-09-10

### Fixed
- インストーラプロンプトは今後、ユーザーが各ステップを確認するまでブロック。競合プラグインの `.bak.*`
  カスケード修正（主 dir は一度だけバックアップ）。古いプラグインは今後 `git fetch --depth 1` +
  `git reset --hard` で実際に更新。

## [v2.1.1] - 2026-09-09

### Added
- **zsh 再インストールプロンプト**：zsh が既にインストール済みなら、brew（macOS）または apt
  （Debian/Ubuntu）で再インストール/アップグレードするよう促す。
- **fast-syntax-highlighting**：`.zshrc` テンプレート内の `zinit light
  zdharma-continuum/fast-syntax-highlighting` で読み込み（Zinit は起動時自動クローン）。install.sh が
  直接管理しない。
- **i18n メッセージ**：zh-CN、zh-TW、ja、ko、en に `prompt.zsh_reinstall` を追加。

### Changed
- **Phase 0**：フルコンボインストールに zsh 再インストールロジックを含める。fast-syntax-highlighting は
  Zinit 経由で `.zshrc` テンプレートから読み込み。
- **Phase 1-3**：starship/atuin/zinit プロンプトの `SKIP_DEPS` ガードを復元。

### Fixed
- zsh 再インストールプロンプトは正しい brew/apt フォールバック論理を使用。

## [v2.1.0] - 2026-09-08

### Added
- **Phase 0/5**：完全推奨コンボインストール（zsh + fzf + starship + atuin + zinit + zsh-smart-complete）。
- **対話式バックアップ清掃**：競合プラグイン残骸（`.cache/p10k-*`、`.cache/zsh*`、
  `.local/state/zsh-autocomplete` 等）の清掃を促す。
- **fzf 自動インストール**：パッケージマネージャで不可なら GitHub からクローン。

### Changed
- `SKIP_DEPS!=1` かつ `NONINTERACTIVE!=1` のとき、インストーラは今後まず Phase 0 を実行。Phase 0 が
  スキップされた場合のみ Phase 1-3 がフォールバック。

## [v2.0.6] - 2026-08-26

### Fixed
- リリースワークフロー：tar/zip 前にファイルを stage し 'file changed' 競合を回避。

## [v2.0.5] - 2026-08-26

### Fixed
- `mirror.chosen` メッセージの不正な変数置換。
- 古い `.bak.*` 残骸を清掃。

## [v2.0.3] - 2026-08-26

### Fixed
- i18n：残るすべての中國語ステータスメッセージを翻訳。
- SSH 入力問題を修正。

## [v2.0.2] - 2026-08-26

### Fixed
- i18n：ミラー選択メニューが完全に国際化。

## [v2.0.1] - 2026-08-26

### Fixed
- 3 件のインストーラ問題を解決：i18n コンボメニュー、OMZ/p10k 既定は yes、starship.toml エスケープ。

## [v2.0.0] - 2026-08-25

### Added
- エンジンとインストーラの刷新。
- O(bucket) 接頭辞索引。
- de-subShell スコアリング。
- リアルタイム増分索引。
- Zsh 検出。
- OMZ/p10k コンボセレクタ。
- Entware インストーラ。
- ZLE 行エディタを乱していた毎キー入力の stdout 漏洩を停止。

## 以前のリリース

```
v0.1.0  ZLE フロントエンド、履歴索引、サジェストエンジン
   │
v0.1.3  決定論的ランク付け（減衰 + 頻度 + CWD ブースト）
   │
v0.2.0  Atuin SQLite バックエンド（host / exit / CWD 対応ランク付け）
   │
v1.0.0  GA — 安定公開 API、CI/CD、自動リリース
   │
v2.0.0  エンジンとインストーラの刷新 — O(bucket) 接頭辞索引、de-subShell
        スコアリング、リアルタイム増分索引、Zsh 検出、OMZ/p10k コンボ
        セレクタ、Entware インストーラ
   │
v2.1.0  Phase 0 フルコンボインストール（zsh + fzf + starship + atuin + zinit +
        zsh-smart-complete）、対話式バックアップ清掃
   │
v2.1.6  印字可能 ASCII 入力修正（undefined-key）、捕獲強化、
        fast-syntax-highlighting、コンボ対応 .zshrc、opt-in zsh-vi-mode
   │
v0.5.x  smart-shell-engine（Rust / Go、IPC 経由）（未来、opt-in）
   │
v2.0    Smart Shell — 完全な独立シェル（未来）
```
