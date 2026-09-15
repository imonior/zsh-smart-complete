# 變更日誌

本專案的所有重要變更都會記錄在此檔案。

格式基於 [Keep a Changelog](https://keepachangelog.com/)，並遵循
[語意化版本](https://semver.org/lang/zh-TW/)。

## [v2.2.0] - 2026-09-15

這個版本終於交付了本外掛存在的**全部理由**：把 `zsh-autocomplete` +
`zsh-autosuggestions` 的兩個功能半邊，在**一個外掛裡**以原生方式實作。

### 新增
- **打字即彈候選選單**（`lib/engine/menu.zsh`）：每編輯一次緩衝區就計算並繪製候選
  清單，於是補全在你打字時就出現——無需按 `Tab`。基於使用者自己的 compsys 之上，透過
  私有補全 widget（`zle -C ... list-choices`）實作：其 completer 讀取
  `compstate[nmatches]` 決定清單是否繪製，從不改動 `compinit`。總開關 `SMART_MENU`，
  執行時 `smart-menu on|off|status`。
- **行內灰字與候選清單共存。** 清單重繪與 `POSTDISPLAY` 爭用同一塊螢幕區域，因此順序
  固定：先畫灰字，再跑列舉，之後絕不重繪。單個候選（`SMART_MENU_MIN_MATCHES`）會撤掉
  清單、讓灰字接管。
- **自適應節流**（`SMART_MENU_SLOW_MS` / `SMART_MENU_COOLDOWN_KEYS`，預設關閉）：耗時
  達到閾值的列舉會換來一段冷卻，留給**持續**很貴的補全。預設關閉，因為實測唯一的尖峰
  是補全子系統載入時的一次性 ~180ms，為它節流只會讓會話裡第一條 `git <TAB>` 丟掉彈窗，
  卻只省下那一次 180ms。
- **`SMART_MENU_DEBUG=/path/to/log`**：每次 tick 的決策（閘門是否拒絕 / 冷卻是否吞掉該
  次編輯 / 命中幾個候選 / 實際花了多少毫秒）追加寫一行。「沒彈出來」 否則與「只有一個候選、
  於是灰字接管」無法區分。
- **`Alt+→` 接受一個詞**：接受行內建議中的一個詞（隨後重新建議剩餘部分）。無建議可接受時
  降級為 zsh 自帶的 `forward-word`。

### 修復
- **嚴重 — 全新會話裡右箭頭沒反應**：只綁了 `ESC [ C`（CSI），但 `TERM=xterm-256color`
  的 `kcuf1` 是 `ESC O C`（*應用游標鍵* 形式），且 ZLE 會把終端切進該模式。於是該鍵落到
  zsh 自帶的 `forward-char`，建議永遠不被接受，而灰字清晰可見——典型的「灰字在、箭頭死」。
  現在綁定所有箭頭編碼，序列清單由 `terminfo` 加 CSI/SS3 兜底建構。
- **嚴重 — 同款終端下 `Alt+→` 也死**：`Alt` 本質就是「先發 `ESC` 再發方向鍵」，因此繼承了
  多編碼問題。舊程式只綁了 `ESC [ 1 ; 3 C`（xterm）和 `ESC ESC [ C`；處於應用游標鍵模式的
  終端發送 `ESC ESC O C`，它未綁定，會把字面 `^[` 塞進緩衝區。`Alt` 形式現在由「給每個
  普通箭頭編碼前綴 `ESC`」**派生**而來，二者不會再漂移。
- **綁定捕獲誤解析原始位元組序列**：`_smart_evt_binding`（`lib/event/zle.zsh`）和
  `_smart_current_binding`（`lib/engine/native.zsh`）用文字匹配去剝鍵名，但 `bindkey` 回顯
  鍵名恆為 `^X` 記法——對原始位元組序列（如 terminfo 的 `kcuf1`）匹配失敗，於是把*鍵文字*存
  成了 widget 名。保存的原始值被污染，解綁時鍵永遠無法還原。兩個解析器現在統一取 `bindkey`
  輸出的末欄位。
- **迴圈內 `local` 洩漏到 stdout**（`lib/event/zle.zsh`）：zsh 5.9 在 `local` 宣告第二次
  執行時會印出 `var='<舊值>'`，而寫在迭代 >1 次的迴圈體內的 `local` 正是如此。那段輸出在 ZLE
  widget 路徑裡直接落到命令列。現在所有迴圈變數都在函式頂部一次性宣告；`tests/test-zle.zsh`
  斷言 bind/unbind 迴圈保持靜默。
- **`zmodload -F` 的 feature 前綴**：`EPOCHREALTIME` 和 `terminfo` 是*參數*，必須用
  `p:EPOCHREALTIME` / `p:terminfo` 請求。被拒的 `b:` 請求讓兩者都未定義——靜默禁用了節流與
  來自 terminfo 的箭頭序列。已加回歸測試。
- **關聯陣列引號下標**：`assoc["km|seq"]=x` 會把引號存進鍵名，導致 `assoc[km|seq]` 取不到。
  現在先用變數拼鍵、再用無引號下標索引（與 `lib/state.zsh` 已有的規則一致）。
- **安裝器**：說明*為何*移除 `zsh-autocomplete` / `zsh-autosuggestions`（兩種行為都已原生
  實作），而不再靜默刪除。

## [v2.1.6] - 2026-09-15

### 修復
- **嚴重 — 可列印 ASCII 輸入被吞**：`_smart_evt_binding` 從 `bindkey -R "^@-^_"` 範圍查詢
  捕獲到偽 widget `undefined-key` 並把可列印鍵發給它，於是 `zle undefined-key`（空操作）吃掉
  了每個 ASCII 按鍵。CJK/UTF-8（位元組 >= 0x80，在重綁範圍外）仍經真正的 `self-insert` 插入——
  因此「中文能打、英文打不出」。捕獲現在把 `undefined-key` 歸一為未綁定以使用 `self-insert`；
  `_smart_evt_dispatch` 也加守衛；`_smart_current_binding`（native.zsh）同樣加固。`tests/test-zle.zsh`
  已加回歸測試。
- **鍵位捕獲加固**：self-insert 的原始 widget 現在硬編碼而非範圍探測（範圍查詢在我們的綁定前
  報 `undefined-key`、綁定後報我們自己的 wrapper，兩者都不是可用原始值）。捕獲由專用標誌
  `_SMART_EVT_CAPTURED` 守衛，而非某個 `ORIG_*` 變數的內容，因此陳舊或手設的
  `_SMART_EVT_ORIG_SELF_*` 再也無法跳過整段捕獲（那會靜默丟掉原生 Tab 綁定及所有其他原始值）。
  捕獲探針額外拒絕記錄任何 `_smart_*` / `smart-*` widget，因此重新捕獲絕不會派發回我們自己的
  wrapper。
- **安裝器 — 受管區塊標記從未寫出**：`build_zsc_integration` 在 bash 腳本裡用了 `print -r --`
  （zsh 內建），呼叫靜默失敗，`# >>> zsh-smart-complete integration (managed) >>>` / `# <<< ... <<<`
  標記列被丟棄。沒有 BEGIN 標記，`_upsert_zsc_block` 永遠匹配不上，於是每次重裝都追加重複塊而非
  原地替換。現改用 `printf '%s\n'`。

### 新增
- **可選 `zsh-vi-mode`（opt-in，預設 NO）**：vi 鍵位確實有用，但本外掛獨佔整張 keymap 且每次
  line-init 都重初始化 ZLE，這正是搞壞其他外掛鍵位的經典做法——因此絕不隱式安裝。使用者選擇時，
  安裝器克隆它並寫入一塊：在 zsh-smart-complete *之前*載入，並透過 `zvm_after_init` /
  `zvm_after_lazy_keybindings` 重新套用我們的 widget。
- **安裝器在流程中安裝 fast-syntax-highlighting**（`_ensure_zinit_plugin
  zdharma-continuum/fast-syntax-highlighting`），完整組合與外掛兩條路徑都裝，不再依賴 Zinit 在首次
  啟動自動克隆。

### 變更
- **安裝器 .zshrc 策略**：完整推薦 `.zshrc` 模板只在本次（重新）安裝了完整堆疊（Phase 0/5 組合）時
  才推薦；僅外掛安裝現在只管理帶標記的 `zsh-smart-complete` 區塊（冪等 upsert，絕不覆蓋整個檔案）。

## [v2.1.5] - 2026-09-15

### 修復
- **安裝器 — p10k/OMZ 清理器**：`_remove_p10k` / `_remove_omz` 現在還會刪除 Zinit 克隆的外掛目錄
  （`$ZINIT_PLUGINS_DIR` 下的 `romkatzen---powerlevel10k`、`OMZ::ohmyzsh---ohmyzsh`），因此選非
  p10k/OMZ 組合能徹底清除下次啟動會重新載入的陳舊殘留。`.bak.*` 產物直接刪除，避免級聯備份。
- **安裝器 — `.zwc` 位元組碼**：外掛更新路徑（`git reset --hard`）現在也會刪除 Zinit 編譯的 `*.zwc`
  快取，於是引擎修復在更新後真正生效（此前載入的是陳舊編譯程式碼）。
- **引擎 — 全域洩漏**：`lib/engine/suggest.zsh` 裡的 `cmd_cwd` / `cmd_host` / `cmd_exit` 現在宣告為
  `local`（此前每次按鍵都洩漏成全域變數）。
- **引擎 — 歷史封頂**：`_SMART_CMDS` 現在封頂到 `SMART_SUGGEST_HISTORY_LIMIT`（預設 20000）；當
  `SMART_HISTORY_REBUILD_EVERY=0` 關閉週期重建時，最舊條目被丟棄且 bucket/assoc 槽保持同步。

## [v2.1.4] - 2026-09-12

### 修復
- fzf 安裝被靜默跳過（無互動）；安裝進度顯示兩次（Phase 0/5 然後 Phase 1-4）。加了 `RAN_COMBO`
  守衛並讓 fzf 提示改為互動式。

## [v2.1.3] - 2026-09-11

### 修復
- 每個 y/N 提示都崩潰 `read: -: invalid option`——`IFS=$'\n\t'` 破壞了 `read $_args`；改為
  `read "$@"`。

## [v2.1.2] - 2026-09-10

### 修復
- 安裝器提示現在阻塞直到使用者確認每一步；衝突外掛 `.bak.*` 級聯修復（主目錄只備份一次）；陳舊外掛
  現在真正透過 `git fetch --depth 1` + `git reset --hard` 更新。

## [v2.1.1] - 2026-09-09

### 新增
- **zsh 重裝提示**：zsh 已安裝時，提示使用者透過 brew（macOS）或 apt（Debian/Ubuntu）重裝/升級。
- **fast-syntax-highlighting**：透過 `.zshrc` 模板裡的 `zinit light
  zdharma-continuum/fast-syntax-highlighting` 載入（Zinit 啟動時自動克隆）；不由 install.sh 直接管理。
- **i18n 訊息**：在 zh-CN、zh-TW、ja、ko、en 中新增 `prompt.zsh_reinstall`。

### 變更
- **Phase 0**：完整組合安裝現在包含 zsh 重裝邏輯；fast-syntax-highlighting 由 Zinit 經 `.zshrc` 模板載入。
- **Phase 1-3**：恢復 starship/atuin/zinit 提示上的 `SKIP_DEPS` 守衛。

### 修復
- zsh 重裝提示使用正確的 brew/apt 回退邏輯。

## [v2.1.0] - 2026-09-08

### 新增
- **Phase 0/5**：完整推薦組合安裝（zsh + fzf + starship + atuin + zinit + zsh-smart-complete）。
- **互動式備份清理**：提示使用者清理衝突外掛殘留（`.cache/p10k-*`、`.cache/zsh*`、
  `.local/state/zsh-autocomplete` 等）。
- **fzf 自動安裝**：套件管理器不可用時從 GitHub 克隆。

### 變更
- 當 `SKIP_DEPS!=1` 且 `NONINTERACTIVE!=1` 時，安裝器現在先跑 Phase 0；Phase 0 被跳過時 Phase 1-3 作為回退。

## [v2.0.6] - 2026-08-26

### 修復
- 發布流程：tar/zip 前先 stage 檔案，避免 "file changed" 競爭。

## [v2.0.5] - 2026-08-26

### 修復
- `mirror.chosen` 訊息中的錯誤變數替換。
- 清理舊的 `.bak.*` 殘留。

## [v2.0.3] - 2026-08-26

### 修復
- i18n：翻譯剩餘所有中文狀態訊息。
- 修復 SSH 輸入問題。

## [v2.0.2] - 2026-08-26

### 修復
- i18n：鏡像選擇選單現已完全國際化。

## [v2.0.1] - 2026-08-26

### 修復
- 解決 3 個安裝器問題：i18n 組合選單、OMZ/p10k 預設選是、starship.toml 轉義。

## [v2.0.0] - 2026-08-25

### 新增
- 引擎與安裝器重構。
- O(bucket) 前綴索引。
- de-subShell 評分。
- 即時增量索引。
- Zsh 偵測。
- OMZ/p10k 組合選擇器。
- Entware 安裝器。
- 停止每次按鍵的 stdout 洩漏（曾搞亂 ZLE 行編輯器）。

## 更早的版本

```
v0.1.0  ZLE 前端、歷史索引、建議引擎
   │
v0.1.3  確定性排序（衰減 + 頻率 + CWD 加成）
   │
v0.2.0  Atuin SQLite 後端（host / exit / CWD 感知排序）
   │
v1.0.0  GA — 穩定公共 API、CI/CD、自動發布
   │
v2.0.0  引擎與安裝器重構 — O(bucket) 前綴索引、de-subShell 評分、
        即時增量索引、Zsh 偵測、OMZ/p10k 組合選擇器、Entware 安裝器
   │
v2.1.0  Phase 0 完整組合安裝（zsh + fzf + starship + atuin + zinit +
        zsh-smart-complete），互動式備份清理
   │
v2.1.6  修復可列印 ASCII 輸入（undefined-key）、捕獲加固、
        fast-syntax-highlighting、組合感知 .zshrc、opt-in zsh-vi-mode
   │
v0.5.x  smart-shell-engine（Rust / Go，經 IPC）（未來，opt-in）
   │
v2.0    Smart Shell — 完整獨立 shell（未來）
```
