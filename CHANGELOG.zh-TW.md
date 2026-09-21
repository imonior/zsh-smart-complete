# 變更日誌

本專案的所有重要變更都會記錄在此檔案。

格式基於 [Keep a Changelog](https://keepachangelog.com/)，並遵循
[語意化版本](https://semver.org/lang/zh-TW/)。

## [v2.2.10] - 2026-09-22

### 修復
- **輸入一個字元看起來就像已經提交了整行：每次按鍵都把終端向上捲一行。** 顯示層最後一句是 `zle -R "" ""`（「強制重繪新的 region_highlight」），而這個形式會讓 zsh 從頭重建自己的提示字元區域。在 pty 上實測 zsh 真正寫出的位元組，兩行提示字元下一次按鍵：**96 位元組，其中含一個 `\r\r\n`**——一個真正的換行，後面跟著游標上移和一整行擦除——而**去掉它是 33 位元組**。終端上游標多數時候就停在最後一行（任何命令輸出都會把它壓到那裡），而在最後一行輸出換行會把整個畫面向上捲一行；緊隨其後的游標上移落到的已經是捲動後的內容，這就是正在輸入的那一行字被「混」在一起（`lls-la /etc/`）的原因。於是每個鍵都像是已經提交、並在下面重新印出一個新提示字元。連灰字**和**彈窗都關掉時，同一次按鍵要花 32 位元組，而原生 zsh 只寫 1 位元組。這行呼叫已從它存在的兩處刪除——`_smart_display_update` 與 `→` 接受路徑。只寫 `region_highlight` 陣列就夠了：widget 返回時 ZLE 會重繪一次，這次重繪會帶上灰字及其顏色（已驗證仍是 `ESC[38;5;110m`）。
- **唯一真正需要的那次重繪，現在只在需要時才發出，而不是每次按鍵都發。** 去掉這條「萬能重繪」暴露出它順帶在做的事：撤回為更長前綴畫出的候選行。清單持續被畫的時候，zsh 自己會維護那塊區域——把 `git st` 收窄到 `git sta` 確實會把三行變成兩行——但**最後一次**轉換，也就是前綴收窄到只剩一個候選、清單被壓住的那一次 tick，根本走不到 zsh 的清單程式碼，於是舊行就一直留在新灰字下面。外掛現在會追蹤「自己畫的行是否還在螢幕上」，並**每次收窄只請求一次**清除重繪（新增 `_smart_menu_forget_rows`），也包括那些按設計什麼都不畫的 tick：閘門關閉與被節流跳過。實測：這次轉換會清乾淨（`git stat` 下面 0 條殘留行，畫面與修復前一致），而普通按鍵仍然只花 33 位元組，兩個功能都關時 1 位元組——與原生 zsh 完全一致。

### 新增
- **`tests/test-repaint.zsh`——針對「每次按鍵 zsh 寫出多少位元組」的回歸測試。** tmux 那套端到端**結構上完全看不到**這一類 bug：tmux 會把「換行 + 游標上移」這一對抵消掉，所以無論外掛是否在每次按鍵時重繪，它的螢幕**和**回捲區都一模一樣。該測試用 `zsh/zpty` 啟動真實的 `zsh -i`，用 `zsh/mapfile` 讀取原始位元組流（用命令替換會把正在被檢驗的那個末尾換行吃掉），並在兩行提示字元下釘住一條不變式：**一次按鍵必須留在同一行**——不出現換行、不出現縱向游標移動、不出現清屏——外加「兩條通道都關時，一次按鍵只花它自己的回顯，別什麼都沒有」。它在修復前的程式碼上失敗、在這裡通過，因此將來若有人把這個重繪加回來，是 CI 先發現，而不是使用者。`smart-menu status` 現在還會報告外掛自己畫的候選行是否仍在螢幕上——那是外掛唯一持有的螢幕狀態。

## [v2.2.9] - 2026-09-22

### 修復
- **有十七個控制鍵失效，包括 Ctrl-A、Ctrl-E、Ctrl-K、Ctrl-L、Ctrl-R、Ctrl-U、Ctrl-W。** 外掛用兩條區間綁定覆蓋所有可列印字元（`bindkey -R "^@"-"^_"` 與 `-R " "-"~"`），而前者**順帶**把每個控制鍵也一併收編了：在 zsh 5.9 上實測，執行後 `bindkey -M emacs '^A'` 回報 `self-insert`，於是 Ctrl-A 插入的是字面控制字元，而不是跳到行首。只有外掛有意包裝的幾個鍵（`^M`、`^Y`、`^_`、`^G`、`^I`）因為之後被重新綁定而倖存。現在在任何自有綁定生效**之前**，先按 keymap 快照每個控制鍵的原始綁定，並在區間綁定之後立刻還原，因此 Ctrl-A/E/F/K/L/N/P/R/T/U/W/V/X（以及 `^A`–`^_` 的其餘鍵）完全依使用者自己的設定運作；隨後需要包裝的鍵再由下方的包裝綁定接管。
- **`SMART_SUGGEST_STRATEGY=history,completion` 的 completion 那一半從未真正產生過建議——而它現在是預設值。** 背後的探針是以 `$( _smart_menu_completion_suffix )` 呼叫的，也就是跑在命令替換裡：`$( )` 會 fork 子 shell，而 `zle` 內建在子 shell 裡無法執行，於是探針靜默返回空、每次按鍵都是 `after == before`，從發布那天起，所有使用者的 completion 策略都是死的。預設值改為 `history,completion` 的理由是：只有 history 時，恰好在使用者最期待提示的地方留下「提示真空」——輸入 `cd /u` 只匹配到一個檔案系統候選，清單被 `SMART_MENU_MIN_MATCHES=2` 壓住，而 `cd /usr/...` 若從未執行過也沒有歷史匹配，畫面上就什麼都沒有。widget 上下文的 `_smart_menu_probe_suffix` 改為透過全域變數返回（不再走 stdout）並被直接呼叫；列印版包裝函式保留給測試與手動除錯，並附註解說明為何它絕不能寫進 `$()`。設 `SMART_SUGGEST_STRATEGY=history` 可恢復舊的僅歷史行為。
- **內聯灰字建議難以與你真正輸入的文字區分，一個字母的前綴看起來像是整條命令已經打完了。** 建議文字由 `region_highlight` 以 `SMART_SUGGEST_COLOR` 上色，預設值是 `fg=8`（亮黑）——在許多主題以及 Ubuntu / WSL 預設調色盤下，這個顏色與正常前景色幾乎相同，於是 `l` 後面跟著暗淡的 `s -la /usr/` 會被讀成整行已經是 `ls -la /usr/`。緩衝區裡其實什麼都沒插入：在 `l` 上按 Enter 執行的是 `l`。預設值現在改為 `auto`：在 256 色終端上解析為 `fg=110`（明顯更暗的藍灰色），透過 `terminfo[colors]` 偵測，並以 `TERM` 兜底（`*256color*`、`*truecolor*` 以及 kitty / Alacritty / WezTerm / iTerm2 / GNOME / Konsole / foot 等已知 256 色終端）；真正的 8/16 色終端上沒有 110 號色，仍用 `fg=8`。顯式設定（`SMART_SUGGEST_COLOR="fg=245,bold"`）依舊原樣生效。
- **候選清單在你按下第一個鍵時就彈出，而且最小長度算的是整條路徑而不是你正在輸入的那一段。** `SMART_MENU_MIN_PREFIX`（以及針對命令詞的 `SMART_MENU_MIN_PREFIX_CMD`）預設是 `1`，所以按下 `l` 就會畫出一張包含所有符合命令與歷史記錄的完整清單，而你其實還沒輸入有意義的內容；在 `/etc/l` 上計數是 6，因為門檻量的是整個 shell 單字，於是剛敲完 `/` 清單也出現了。兩個鍵現在預設 `2`，且**只統計最後一個 `/` 之後的那一段**——`/etc/l` 算一個字元，`/etc/lo` 才打開清單。上限 `SMART_MENU_MAX_PREFIX` 仍然按整個單字計算。注意：清單一旦畫出就是普通終端輸出，zsh 不會清除它（原生 zsh 行為相同），所以「少畫清單」是唯一的手段——曾實作「畫完再清除」並實測無效，已移除。
- **Starship 一直渲染它自己的預設提示符，而不是推薦的兩行佈局。** 透過 `curl ... | bash` 安裝時沒有 `templates/` 目錄，設定來自第二份內聯副本——而那份副本少了 `format =` 行。沒有 `format` 時 starship 會靜默忽略檔案其餘部分並印出自己的預設樣式（`hostname in ~ via 🐍 ... ❯`），這正是全新安裝 v2.2.8 後看到的現象。兜底副本現在與 `templates/starship.toml.example` 逐位元組一致（單一規範寫入函式，由安裝器測試第 21 節釘死）；已存在的 `starship.toml` 現在會被分類：**推薦設定**（同時含 `success_symbol = "[:> ](bold green)"` 標記與 `format` 鍵）原樣保留；**舊版設定**（早期版本寫入、沒有 `format` 鍵）自動修復，先備份為 `~/.config/starship.toml.bak.<時間戳>`，不再提問；**自訂設定**仍然先詢問。
- **安裝器裡仍硬編碼為英文的輸出文字。** 剩餘部分——套件管理員提示、zsh / Oh-My-Zsh / atuin / fzf / starship / Entware 各段、清理、備份、powerlevel10k、`.zshrc` 與組合片段——現已全部走 i18n 表，五種語言齊全：`install.sh` 有 234 個鍵、`install-entware.sh` 有 150 個，硬編碼輸出字串為 0、渲染為空的鍵為 0，且每個被引用的鍵都有定義——此前有 5 個鍵完全沒有定義，直接把鍵名印了出來（主安裝器的 `i.fzf_not_in_feed`，以及 Entware 安裝器的 `w.omz_failed`、`w.zsh_theme_write_failed`、`s.zsh_theme_set`、`s.zsh_theme_appended`）（安裝器測試第 22 節）。

## [v2.2.8] - 2026-09-21

### 修復
- **安裝器的語言選擇選單曾把每個選項都顯示成英文，導致不認識英文的使用者選不了自己的語言。** `select_language` 過去透過 `msg lang.option_*` 渲染五個選項，而該表跟隨 `LANG_CODE`、在預設語言（`en`）下回退為英文，於是整個選單變成英文。現在選單始終用各語言的本族語（endonym）列印：`English / 简体中文 / 繁體中文 / 日本語 / 한국어`，每位使用者都能憑自己的文字認出對應選項，無需懂英文。已刪除無用的 `lang.option_*` 鍵，使 `install.sh` 與 `install-entware.sh` 攜帶完全相同的 i18n 表與選單；此一致性由新增的安裝器測試（第 18 節）釘死。

## [v2.2.7] - 2026-09-19

### 修復
- **安裝器全部用預設設定，螢幕上仍然同時出現兩個動態提示：外掛的彈窗之外，還多出 atuin 自己的浮動搜尋介面。** 推薦設定過去只要偵測到 `atuin` 二進位就無條件執行 `eval "$(atuin init zsh --disable-up-arrow)"`。該參數只解綁上箭頭：atuin 仍會綁定 **Ctrl-R**，且目前版本還會綁定 **`?`**（Atuin AI）——它的 TUI 是第二個全螢幕介面（浮動列出所有符合的歷史記錄、含重複項、Enter 即執行），就出現在外掛彈窗旁邊。而外掛本來就直接讀取 atuin 的 SQLite 歷史資料庫來產生灰色建議，這些按鍵綁定毫無收益。現在產生的設定改為 `ATUIN_NOBIND="true" eval "$(atuin init zsh)"`：歷史記錄與外掛的 atuin 後端不受影響，但 ↑ / Ctrl-R / ? 保持原生，螢幕上始終只有一個介面。是否綁定 atuin 的 TUI 改為安裝器中的明確提問（預設否，五種語言都有），且 atuin init 行從組合片段移入整合區塊——atuin 記錄現在對所有組合生效（此前 Oh-My-Zsh / p10k 組合被靜默漏掉）。隨附的 `templates/zshrc.example` 同步該規則。新增唯讀提示 `_scan_foreign_atuin`：發現在外掛託管區塊**之外**的 `atuin init` 行（例如早期手動設定留下的）會明確警告，否則它們會悄悄把第二個介面帶回來。

## [v2.2.6] - 2026-09-19

### 修復
- **行內灰字建議失去顏色，且每敲一個鍵就殘留一條殭屍高亮條目。** 外掛 `region_highlight` 處理上的兩個缺陷，都靠能識別顏色的 tmux 探針證實。1) 標記我們條目的記號原本是 `#註釋` 文字——而 zsh 每次重繪都會把 `region_highlight` 裡的註釋文字丟掉——於是過濾舊條目的匹配從此失效，殭屍條目隨每次按鍵累積（實測：5 個鍵 -> 8 條；載入 fast-syntax-highlighting 後 -> 171 條）。現在改用 `memo=` 記號，zsh 會原樣保留。2) 繪製候選清單會讓 zsh 重刷整行，並把任何伸進 POSTDISPLAY 的高亮條目裁回 BUFFER 末尾（零長度 = 不上色）。外掛現在在每次畫完清單後立即重寫該條目——不額外重繪，清單保持原樣。已對 zsh-syntax-highlighting 與 fast-syntax-highlighting 雙雙驗證：都能正確共存，無需任何相容鉤子——此前「F-Sy-H 會清掉外來條目」的結論是錯的。
- **`bash -c "$(curl -fsSL .../install.sh)"` 報 `argument list too long: bash`。** install.sh 已經超過 Linux 單一參數 128 KiB 上限（`MAX_ARG_STRLEN`）。所有文件統一改為管線寫法 `curl -fsSL .../install.sh | bash`（鏡像形式：`curl -fsSL .../install.sh | SMART_INSTALL_GH_MIRROR=... bash`），完全不經過 argv 傳腳本。
- **管線安裝時提示不等輸入**（`curl ... | bash`）：stdin 就是腳本本身，普通 `read` 立刻返回空，語言 / 代理 / 鏡像選單全部靜默取預設值。所有互動讀取現在統一走 `_tty_read`（重新開啟 `/dev/tty`）。`BASH_SOURCE[0]` 也加了守衛——腳本從 stdin 進來時它未設定（`set -u` 下腳本直接中止；不中止時 `SCRIPT_DIR` 會靜默變成呼叫者的目前目錄）。
- **Starship 解析錯誤 `Error parsing "format": --> 1:7`（`[$user] › $directory`）。** 兩個錯誤疊加：starship 頂層的 `[文字]` 分組必須帶 `(樣式)` 後綴；且頂層變數名是 `$username`（`$user` 只在 `[username]` 模組內部有效）。範本改為 `$username › $directory`；兩份副本（範例範本與 Entware 安裝器內聯的那份）都由迴歸測試釘死——測試會用真實的 `starship` 二進位渲染設定。

## [v2.2.5] - 2026-09-19

### 新增
- **其它啟動檔中的衝突載入器探測（唯讀提醒）。** 安裝器的衝突清理只編輯 `~/.zshrc`——這是刻意的设计，避免改動使用者在別處管理的設定。但 `zsh-autocomplete` / `zsh-autosuggestions` 的載入行有時會寫在 `.zprofile`、`.zshenv`、`conf.d/*.zsh`、`.zshrc.d/*` 或 `/etc/zsh/zshrc` 裡。這些載入行一旦殘留，每次 `exec zsh` 仍會載入對應套件，重新觸發重複建議 / Tab 衝突。清理之後，安裝器現在會**掃描**這些檔案，並用精確的 `檔案:行號` **警告**使用者手動清理——它從不修改這些檔案。

- **IP 歸屬地偵測決定「可見候選」：非中國大陸隱藏預置鏡像，但直連照舊測速。** 外網 IP 歸屬地偵測有三種結果：**中國大陸**、**非中國大陸**、**沒偵測出來**。中國大陸 / 沒偵測出來：顯示全部候選並全部測速——**包括 direct**，因為直連是否真的更快應該測出來而不是靠地區猜——且始終提供兩項手動輸入；地區不明時也不隱藏任何東西，把選擇權留給使用者。**非中國大陸：隱藏全部預置鏡像**（ghproxy 系列與 gitclone.com 都是大陸專用通道，在這個地區只會誤導或更慢），只保留 direct——但 direct **仍然照常測速**，兩項手動輸入（鏡像源、全量代理）也照舊保留。選單編號按可見候選壓緊，不會留下「選了沒反應」的空位。同時**移除了 `kgithub.com`**——網域替換型鏡像無法長期穩定服務。
- **兩種手動輸入：鏡像源，或全量代理。** 這是兩種真正不同的機制，所以現在都提供。**鏡像源**改寫 GitHub URL（前綴或網域替換）；**全量代理**——可設為系統代理的那種，如 `http://127.0.0.1:7890` 或 `socks5://127.0.0.1:1080`——則匯出為 `HTTP_PROXY`/`HTTPS_PROXY`，讓 curl/git/wget 的**每一個**請求都走它（URL 保持原樣）。全量代理在採納前會做可用性檢測，也可用 `SMART_INSTALL_PROXY` 以非互動方式指定。
- **預置鏡像源標註「適用於中國大陸」。** ghproxy.net / ghproxy.com / mirror.ghproxy.com / gitclone.com 本來就是為大陸網路服務的，因此標籤裡明確標註——否則中國大陸以外的使用者很容易選到一個比直連更慢的通道。

### 修復
- **衝突探測不再把歷史備份重複回報為殘留。** zinit 目錄掃描依子字串比對，上一輪執行留下的 `zsh-autocomplete.bak.<時間戳>` 備份目錄會被再次回報為「發現衝突套件目錄」——即便真實套件早已移除；一旦確認移除，該備份還會被刪除。現在備份目錄會被跳過（它們不是作用中的套件），只回報真正的套件目錄。
- **唯讀掃描不再把 `fzf-tab` 當成衝突。** `fzf-tab` 是受支援的替代清單繪製器（`SMART_MENU_LISTER=fzf-tab`），把它回報為衝突與已發布的整合方式自相矛盾。現在只回報 `zsh-autocomplete` / `zsh-autosuggestions` 這兩個與 zsh-smart-complete 功能完全重複的套件。

## [v2.2.4] - 2026-09-16

### 新增
- **`SMART_MENU_LISTER=builtin|fzf-tab`——顯式的二選一。** 兩個補全清單器都有資格繪製，
  所以「畫面上同時出現兩個彈窗」不是其中任何一個能修的 bug：必須有一個停下來。這個選擇現在
  是一項設定，而不是靠推斷：

  ```zsh
  smart-lister                   # 現在歸誰
  smart-lister fzf-tab           # 本外掛不畫，交給外部浮動選擇器
  smart-lister builtin           # 收回來
  ```

  交出去的只是**清單**：行內灰字建議照常運作，`SMART_MENU` 也不受影響，所以
  `smart-lister builtin` 是一次完整的復原。`builtin`、`smart`、`internal`、`native`、
  `built-in`、`on`、`yes`、`true`、`1` 都表示本外掛；`fzf-tab`、`fzf_tab`、`fzf`、
  `ftb`、`external`、`none`、`off`、`no`、`false`、`0` 都表示交出去（`off` 是「本外掛的
  清單關掉」，不是「完全沒有清單」——後者是 `SMART_MENU=false`）。無法辨識的參數會**被明確
  報錯並回傳非零**，不再默默印出狀態區塊——先前一個拼字錯誤看起來就像切換成功了。這項設定
  **不會**安裝 fzf-tab；安裝器的 fzf-tab 提問才負責安裝，並會把對應的
  `SMART_MENU_LISTER` 寫進受管區塊，使回答在重複執行時保留。
- `smart-doctor` 現在會報告清單歸屬；當清單被交給一個**並未載入**的選擇器時會提出警告——
  而且這條警告的優先序高於其他所有結論，因為「什麼都畫不出來」比「出現兩個清單」更糟。
  最初的結論只依據「載入了多少個外來補全鉤子」來判斷，而在這種情況下它恰好是 0，於是它會
  宣布 shell 健康，儘管根本不可能有清單出現。

### 變更

### 變更
- **單列改為可選，預設關閉。** v2.2.3 把它設成預設，這是錯的：垂直清單只能靠
  *自行產生*候選來畫，而產生候選要付出真實的功能代價。
  - 它**繞過了 `_main_complete`**，因此它涵蓋的場景會失去候選**描述**、
    `list-colors` 著色、分組，以及 `matcher-list`——文件裡那條模糊匹配**不適用於**產生的候選。
  - 只會產生指令 / 函式 / 別名 / 內建、檔案系統路徑與 `cd` 最近目錄。其餘場景（git 子指令、
    ssh 主機、`--選項`、`sudo …`）會退回原生網格，因此**彈窗會在輸入過程中變形**——很容易
    被誤認為「又多出一個清單」。
  - 超過終端寬度的候選會被截斷（沒有省略號）。
  沒有刪除任何東西：`SMART_MENU_SINGLE_COLUMN=true` 仍然是 v2.2.3 那個垂直清單。安裝器現在
  會就此提問（預設**否**），並把代價寫在問題裡。
- `tests/e2e-tmux.sh` 增至 **41** 項。場景 10 依序斷言單列契約——預設是網格（10a）、
  開啟後每行一個（10b）、關閉後網格回歸（10c）；10a 與 10c 正是讓 10b 可失敗、而非空過的
  前提。場景 11 走的是清單器開關的 BEFORE → OFF → BACK ON：只有這個結構才能讓中間那一步
  有意義（沒有「切回來」這一步，「零行」同樣可以由「壓根不補全了」滿足），它還會斷言行內
  灰字建議在交接後仍然存活。
- v2.1.6 的 A/B 基線是**實測**的、**不是按比例換算**的：**20/41**。在 v2.1.6 上既沒有
  彈窗也沒有這個開關，因此 10a/10b/10c 失敗，場景 11 也大部分失敗。該區域仍有 3 條通過，而
  **其中只有 1 條是真的**——行內灰字建議在交接後仍然存活（v2.1.6 同樣有 `POSTDISPLAY`）。
  另外兩條——10b 的「沒有一行塞兩個候選」與 11b 的「交接後我們不畫清單」——是**空過**，因為
  那個版本根本不會畫任何清單。能把這三種通過區分開，正是基線必須實跑、而不能從舊分數推出來
  的原因。
- `tests/test-menu.zsh`：144 → 183。場景 5 現在**直接驅動 `smart-lister` CLI**，對每一個
  被接受的拼寫斷言三處編碼這份清單的地方保持一致。它們分別寫在不同位置（正規化函式、
  「是否被辨識」檢查、以及 CLI），而且**已經漂移過**：CLI 接受 `on` 而辨識函式不認——於是
  `smart-lister on` 成功、緊接著的 `smart-lister` 卻自相矛盾；而 `no`/`false`/`0` 對兩個
  輔助函式是 fzf-tab，在 CLI 裡卻落到狀態輸出。手抄一份拼字清單抓不到這種問題——上一輪正是
  這麼漏掉的。`smart-doctor` 新的「已交接」結論在場景 13b 裡被釘住，包括它的**誤報**一側
  （一個**確實已載入**的選擇器必須能清除警報）。
- `tests/test-config.zsh`：39 → 43。新增場景 5 固化那個已經漂移過兩次的值：5 份 README 裡
  寫明的單列預設值必須等於 `lib/config.zsh` 的實際預設值。
- 合計：**590 項斷言**（9 個 zsh 套件共 532 項 + 安裝器套件 58 項）；e2e **41/41**。

## [v2.2.3] - 2026-09-16

### 修復
- **`Delete` 鍵會留下行內殘影。** 退格鍵早已被接管，但 `Delete`（`ESC [ 3 ~`）沒有：
  叫出歷史補全後再按 Delete 刪掉一個字元，上一條建議會**凍結**在畫面上。現在 Delete 與
  退格鍵一樣被接管（emacs / viins 兩個鍵盤表），並在卸載時原樣歸還。
- **單列彈窗其實一直在用網格渲染。** 填充寬度寫成了一行
  `local cols=... pad="$cols"`——而 `local` 命令的所有展開都發生在兩個賦值**之前**，因此
  `pad` 是空字串，`${(r...)…}` 以寬度 0 填充，清單自然還是多欄，**程式碼看起來卻是對的**。
  現在寬度改以變數名傳給填充（`${(r.cols.. .)...}`）。

### 新增
- **單列（垂直）即時彈窗**——`SMART_MENU_SINGLE_COLUMN`，預設 `true`。輸入即時彈窗改為
  **每行一個候選**，不再使用 zsh 原生的多欄網格。做法是直接產生候選（指令 / 函式 / 別名、
  檔案系統路徑、`cd ` 最近目錄），並把每一條**顯示字串**填充**或截斷**到恰好 `COLUMNS`
  寬——這在數學上只能容下一欄。設為 `false` 即回到原生網格。
  - 為何是「產生」而不是「截取」：把 `compadd` 換成函式後，某些 zsh 版本會**完全不再加入
    候選**（已實測），那會讓彈窗靜默變空。
  - 輸入會先轉義才送進 glob 引擎：先前輸入的 `[` 會拼出模式 `[*`，而「壞模式」不是
    nomatch——它會**中斷**產生器並在**每一次按鍵**都印出 `bad pattern:`。但開頭的 `~/`
    刻意**不**轉義，否則所有 `~/…` 候選都會消失。
  - 保留了退回機制：產生器涵蓋不到的場景（git 子指令、ssh 主機、選項字串）仍會執行你真正的
    補全。
- **`smart-doctor`**——把「還有誰能在畫面上畫出第二個候選清單」的指紋全部印出來：
  `_main_complete` / `compadd` / `_complete` 是否仍是 zsh 原生入口，是否載入了
  zsh-autocomplete / zsh-autosuggestions / fzf-tab / 語法高亮，每個鍵盤表裡 `Tab` 歸誰，
  哪些 zstyle 能開啟清單，以及本外掛自身的狀態——最後給一句結論。**唯讀**，因此在半壞掉的
  shell 裡也能安全執行。
- **安裝器的可選設定改為互動式。** fzf-tab、Tab 選單、單列版面、最近目錄、↑/↓ 歷史搜尋、
  zsh-vi-mode 與建議來源都會在安裝時逐項詢問，回答會寫進所產生 `~/.zshrc` 的一個受管區塊。
  `install.sh` 與 `install-entware.sh` 均已支援。
  - 該區塊刻意位於**外掛載入之前**：部分選項（尤其 `SMART_MENU_HISTORY_KEYS`）是在外掛安裝
    按鍵綁定的**那一刻**讀取的，寫在載入之後會被靜默忽略。
  - fzf-tab 預設**關閉**（需主動勾選）；一旦啟用，會強制關掉內建的可選擇選單——兩者同開
    正是兩個清單器搶同一塊畫面的由來。
  - `NONINTERACTIVE=1` 時全部取文件預設值。

### 變更
- **修正 `starship.toml` 範本。** 頂層 `format` 寫了 `[$user]($style)`，而 `($style)` 只在
  各 `[section]` 內部有效，導致**使用者名稱被吞掉**。現在第一行是 `[$user] › $directory`，
  第二行是 `$character`。
- 安裝器的 `.zshrc` 範本新增了受管的選項槽位；結尾那段「Optional:」註解換成了**沒有**被做成
  問題的其他可調項。

### 測試
- `tests/test-menu.zsh`：109 → 144。新增場景 13b（`smart-doctor`）與場景 14（單列候選產生，
  以及單列不變式：每條顯示字串都恰好 `COLUMNS` 寬，且填充/截斷絕不會動到真正被插入的文字）。
- `tests/test-zle.zsh`：93 → 102。兩個鍵盤表的 `Delete` 綁定、卸載時歸還，以及每次按鍵都不得
  輸出到 stdout。
- `tests/test-config.zsh`：37 → 39。`SMART_MENU_SINGLE_COLUMN` 的預設值與使用者覆寫。
- **`tests/test-installer-options.sh`（新增，54 項斷言，bash）**——把安裝器的選項機制抽出來，
  對臨時檔驅動。它固化的正是原始碼裡看不出來的那一條：受管區塊必須落在**外掛載入之前**，且
  重複執行必須幂等。它也會把每一項安裝器預設值與 `lib/config.zsh` 對照——正是這條對照抓出了
  Tab 選單預設值與實際發佈值不一致。
- `tests/e2e-tmux.sh`：29 → 33。**10** 斷言 6 個候選佔 6 行、全部列出、且沒有任何一行塞兩個；
  **10b** 打開 `SMART_MENU_SINGLE_COLUMN=false` 並斷言網格回歸，以此證明 10 確實可能失敗。
- 合計：**538 項斷言**（9 個 zsh 套件共 484 項 + 安裝器套件 54 項）；e2e **33/33**。

## [v2.2.2] - 2026-09-16

### 修復
- **`Tab` 之後按 `Enter` 現在會真正執行該行**，而不只是重繪。此前補全之後，第一次
  `Enter` 會被 accept-line widget 吞掉（它把補全當成仍「進行中」，只刷新顯示），於是
  補全過的 `cd …` 需要**再按一次** `Enter` 才執行。現在該 widget 先清理自身狀態，再直接
  呼叫 `zle .accept-line`。這是個**歷史遺留缺陷**——在 v2.2.1 上可重現。

### 新增
- **最近目錄候選**（`lib/engine/recent.zsh`，`SMART_RECENT_PATHS`，預設 `true`）。補全
  `cd` / `pushd` / `chdir` 參數時，會把你**真正去過**的目錄作為候選；並且在 `cd ` 後的
  **空詞**上立即列出——這是空詞唯一值得列表的場景。實作方式是把一個補全器前置到
  `zstyle ':completion:*' completer`，因此與你自己的補全鏈共存，`smart-recent off` /
  `smart-disable` 時乾淨移除。
- **唯讀。** 資料是 zsh 自帶的最近目錄資料庫（`cdr` 與 `~[1]` 用的同一個），外掛**從不
  寫入**。`SMART_RECENT_PATHS_MAX`（預設 `20`）限制候選數量；`smart-recent status` 報告
  目前可用項目數。
- **`smart-recent on|off|toggle|status`** 執行階段指令。

### 變更
- **模糊匹配只做文件說明，不自行實作。** 即時彈窗跑的就是你自己的補全系統，所以一條
  `zstyle ':completion:*' matcher-list` 已經自動生效——本外掛**刻意不含**模糊匹配程式碼，
  自己加只會和 compsys 打架。README 的「可選增強」一節給出了要設的那一行。

### 測試
- `tests/test-recent.zsh`（38 項斷言）：`cd` 參數位置判定、資料庫解析（空格 / 引號 / XDG
  路徑 / 失效項目），並**固化一條回歸**——補全器是透過 `zstyle ':completion:*' completer`
  接入的，**不是** `$completer` 陣列（那個變數在 zsh 裡根本不存在，之前程式碼「看起來接好了」
  其實什麼都沒做）。
- `tests/e2e-tmux.sh`：新增 **8b**（Tab 後按 Enter 會執行該行）與 **9**（`cd ` 列出最近
  目錄，Tab 補全出完整路徑）。共 29 項斷言；**在 v2.1.6 上為 17/29**。

## [v2.2.1] - 2026-09-16

### 修復
- **即時彈窗不再吞按鍵。** 之前用 `LISTMAX=-1` 作用域包裹列表呼叫（用來壓掉 zsh 的
  「是否顯示全部 N 項（M 行）」提示），會破壞 ZLE 的下一次輸入讀取：輸入 `git status`
  實際進入緩衝區的是 `gitstatus`，shell 執行的是**錯命令**。現在**完全不碰 `LISTMAX`**，
  改為對超大候選清單直接不繪製（`SMART_MENU_MAX_MATCHES`，預設由「不封頂」改為 `100`）
  ——這是實測在「短候選清單」與「1200 項目錄」兩種情境下都乾淨的唯一設定。
- `smart-menu status` 與 tick 除錯日誌現在能區分「低於下限」與「超過上限」，先前兩者
  都被寫成 `below min`，會把排查方向帶偏。

### 新增
- **`SMART_SUGGEST_STRATEGY`**（`history` | `history,completion`，與
  zsh-autosuggestions 同名）。加上 `completion` 後，灰色建議可以來自補全系統——路徑、
  選項、子命令等歷史裡沒有的內容，做法是取游標處單詞的「無歧義前綴」。
- **具名可改鍵 widget**：`smart-accept-suggestion`、`smart-accept-word`、
  `smart-execute-suggestion`、`smart-suggestion-toggle`。
- **`SMART_MENU_HISTORY_KEYS`**（預設 `false`）：設為 `true` 時，行內非空則 ↑/↓ 依前綴
  搜尋歷史（zsh-autocomplete 的招牌行為），行內為空則退回原生歷史導覽。

### 測試
- `tests/e2e-tmux.sh` 新增真終端下的**緩衝區完整性**斷言：逐字輸入不得丟字元，且**真正
  被執行的命令**就是輸入的那一條。先前的案例只斷言「清單有沒有畫出來」，因此彈窗在破壞
  每一條命令列的同時測試仍然全綠。

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
