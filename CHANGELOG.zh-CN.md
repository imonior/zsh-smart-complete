# 更新日志

本项目的所有重要变更都会记录在此文件。

格式基于 [Keep a Changelog](https://keepachangelog.com/)，并遵循
[语义化版本](https://semver.org/lang/zh-CN/)。

## [v2.2.8] - 2026-09-21

### 修复
- **安装器的语言选择菜单曾把每个选项都显示成英文，导致不认识英文的用户选不了自己的语言。** `select_language` 过去通过 `msg lang.option_*` 渲染五个选项，而该表跟随 `LANG_CODE`、在默认语言（`en`）下回退为英文，于是整个菜单变成英文。现在菜单始终用各语言的本族语（endonym）打印：`English / 简体中文 / 繁體中文 / 日本語 / 한국어`，每个用户都能凭自己的文字认出对应选项，无需懂英文。已删除无用的 `lang.option_*` 键，使 `install.sh` 与 `install-entware.sh` 携带完全一致的 i18n 表与菜单；该一致性由新增的安装器测试（第 18 节）钉死。

## [v2.2.7] - 2026-09-19

### 修复
- **安装器全部用默认设置，屏幕上仍然同时出现两个动态提示：插件的弹窗之外，还多出 atuin 自己的浮动搜索界面。** 推荐配置过去只要检测到 `atuin` 二进制就无条件执行 `eval "$(atuin init zsh --disable-up-arrow)"`。该参数只解绑上箭头：atuin 仍会绑定 **Ctrl-R**，且当前版本还会绑定 **`?`**（Atuin AI）——它的 TUI 是第二个全屏界面（浮动列出所有匹配的历史记录、含重复项、回车即执行），就出现在插件弹窗旁边。而插件本来就直接读取 atuin 的 SQLite 历史数据库来生成灰色建议，这些按键绑定毫无收益。现在生成的配置改为 `ATUIN_NOBIND="true" eval "$(atuin init zsh)"`：历史记录与插件的 atuin 后端不受影响，但 ↑ / Ctrl-R / ? 保持原生，屏幕上始终只有一个界面。是否绑定 atuin 的 TUI 改为安装器中的显式提问（默认否，五种语言都有），且 atuin init 行从组合片段移入集成块——atuin 记录现在对所有组合生效（此前 Oh-My-Zsh / p10k 组合被静默漏掉）。随附的 `templates/zshrc.example` 同步该规则。新增只读提示 `_scan_foreign_atuin`：发现在插件托管块**之外**的 `atuin init` 行（例如早期手动配置留下的）会明确警告，否则它们会悄悄把第二个界面带回来。

## [v2.2.6] - 2026-09-19

### 修复
- **行内灰字建议失去颜色，且每敲一个键就残留一条僵尸高亮条目。** 插件 `region_highlight` 处理上的两个缺陷，都靠能识别颜色的 tmux 探针实锤。1) 标记我们条目的记号原本是 `#注释` 文本——而 zsh 每次重绘都会把 `region_highlight` 里的注释文本丢掉——于是过滤旧条目的匹配从此失效，僵尸条目随每次按键累积（实测：5 个键 -> 8 条；加载 fast-syntax-highlighting 后 -> 171 条）。现在改用 `memo=` 记号，zsh 会原样保留。2) 绘制候选列表会让 zsh 重刷整行，并把任何伸进 POSTDISPLAY 的高亮条目裁回 BUFFER 末尾（零长度 = 不上色）。插件现在在每次画完列表后立即重写该条目——不额外重绘，列表保持原样。已对 zsh-syntax-highlighting 与 fast-syntax-highlighting 双双验证：都能正确共存，无需任何兼容钩子——此前「F-Sy-H 会清掉外来条目」的结论是错的。
- **`bash -c "$(curl -fsSL .../install.sh)"` 报 `argument list too long: bash`。** install.sh 已经超过 Linux 单参数 128 KiB 上限（`MAX_ARG_STRLEN`）。所有文档统一改为管道写法 `curl -fsSL .../install.sh | bash`（镜像形式：`curl -fsSL .../install.sh | SMART_INSTALL_GH_MIRROR=... bash`），完全不经过 argv 传脚本。
- **管道安装时提示不等输入**（`curl ... | bash`）：stdin 就是脚本本身，普通 `read` 立刻返回空，语言 / 代理 / 镜像菜单全部静默取默认值。所有交互读取现在统一走 `_tty_read`（重新打开 `/dev/tty`）。`BASH_SOURCE[0]` 也加了守卫——脚本从 stdin 进来时它未设置（`set -u` 下脚本直接中止；不中止时 `SCRIPT_DIR` 会静默变成调用者的当前目录）。
- **Starship 解析错误 `Error parsing "format": --> 1:7`（`[$user] › $directory`）。** 两个错误叠加：starship 顶层的 `[文本]` 分组必须带 `(样式)` 后缀；且顶层变量名是 `$username`（`$user` 只在 `[username]` 模块内部有效）。模板改为 `$username › $directory`；两份副本（示例模板与 Entware 安装器内联的那份）都由回归测试钉死——测试会用真实的 `starship` 二进制渲染配置。

## [v2.2.5] - 2026-09-19

### 新增
- **其它启动文件中的冲突加载器探测（只读提醒）。** 安装器的冲突清理只编辑 `~/.zshrc`——这是刻意的设计，避免改动用户在别处管理的配置。但 `zsh-autocomplete` / `zsh-autosuggestions` 的加载行有时会写在 `.zprofile`、`.zshenv`、`conf.d/*.zsh`、`.zshrc.d/*` 或 `/etc/zsh/zshrc` 里。这些加载行一旦残留，每次 `exec zsh` 仍会加载对应插件，重新触发重复建议 / Tab 冲突。清理之后，安装器现在会**扫描**这些文件，并用精确的 `文件:行号` **警告**用户手动清理——它从不修改这些文件。

- **IP 归属地检测决定「可见候选」：非中国大陆隐藏预置镜像，但直连照旧测速。** 外网 IP 归属地检测有三种结果：**中国大陆**、**非中国大陆**、**没检测出来**。中国大陆 / 没检测出来：显示全部候选并全部测速——**包括 direct**，因为直连是否真的更快应该测出来而不是靠地区猜——且始终提供两项手动输入；地区不明时也不隐藏任何东西，把选择权留给用户。**非中国大陆：隐藏全部预置镜像**（ghproxy 系列与 gitclone.com 都是大陆专用通道，在这个地区只会误导或更慢），只保留 direct——但 direct **仍然照常测速**，两项手动输入（镜像源、全量代理）也照旧保留。菜单序号按可见候选压紧，不会留下「选了没反应」的空位。同时**移除了 `kgithub.com`**——域名替换型镜像无法长期稳定服务。
- **两种手动输入：镜像源，或全量代理。** 这是两种真正不同的机制，所以现在都提供。**镜像源**改写 GitHub URL（前缀或域名替换）；**全量代理**——可设为系统代理的那种，如 `http://127.0.0.1:7890` 或 `socks5://127.0.0.1:1080`——则导出为 `HTTP_PROXY`/`HTTPS_PROXY`，让 curl/git/wget 的**每一个**请求都走它（URL 保持原样）。全量代理在采纳前会做可用性检测，也可用 `SMART_INSTALL_PROXY` 以非交互方式指定。
- **预置镜像源标注「适用于中国大陆」。** ghproxy.net / ghproxy.com / mirror.ghproxy.com / gitclone.com 本来就是为大陆网络服务的，因此标签里明确标注——否则中国大陆以外的用户很容易选到一个比直连更慢的通道。

### 修复
- **冲突探测不再把历史备份重复报告为残留。** zinit 目录扫描按子串匹配，上一轮运行留下的 `zsh-autocomplete.bak.<时间戳>` 备份目录会被再次报成「发现冲突插件目录」——即便真实插件早已移除；一旦确认移除，该备份还会被删除。现在备份目录会被跳过（它们不是活动插件），只报告真正的插件目录。
- **只读扫描不再把 `fzf-tab` 当作冲突。** `fzf-tab` 是受支持的替代列表绘制器（`SMART_MENU_LISTER=fzf-tab`），把它报为冲突与已发布的集成方式自相矛盾。现在只报告 `zsh-autocomplete` / `zsh-autosuggestions` 这两个与 zsh-smart-complete 功能完全重复的插件。

## [v2.2.4] - 2026-09-16

### 新增
- **`SMART_MENU_LISTER=builtin|fzf-tab`——显式的二选一。** 两个补全列表器都有资格绘制，
  所以「屏幕上同时出现两个弹窗」不是其中任何一个能修的 bug：必须有一个停下来。这个选择现在
  是一项设置，而不是靠推断：

  ```zsh
  smart-lister                   # 现在归谁
  smart-lister fzf-tab           # 本插件不画，交给外部浮动选择器
  smart-lister builtin           # 收回来
  ```

  交出去的只是**列表**：行内灰字建议照常工作，`SMART_MENU` 也不受影响，所以
  `smart-lister builtin` 是一次完整的撤销。`builtin`、`smart`、`internal`、`native`、
  `built-in`、`on`、`yes`、`true`、`1` 都表示本插件；`fzf-tab`、`fzf_tab`、`fzf`、
  `ftb`、`external`、`none`、`off`、`no`、`false`、`0` 都表示交出去（`off` 是「本插件的
  列表关掉」，不是「完全没有列表」——后者是 `SMART_MENU=false`）。无法识别的参数会**被明确
  报错并返回非零**，不再默默打印状态块——此前一个拼写错误看起来就像切换成功了。这项设置
  **不会**安装 fzf-tab；安装器的 fzf-tab 提问才负责安装，并会把对应的
  `SMART_MENU_LISTER` 写进受管区块，使回答在重复运行时保留。
- `smart-doctor` 现在会报告列表归属；当列表被交给一个**并未加载**的选择器时会给出警告——
  而且这条警告的优先级高于其他所有结论，因为「什么都画不出来」比「出现两个列表」更糟。
  最初的结论只依据「加载了多少个外来补全钩子」来判断，而在这种情况下它恰好是 0，于是它会
  宣布 shell 健康，尽管根本不可能有列表出现。

### 变更

### 变更
- **单列改为可选，默认关闭。** v2.2.3 把它设成了默认，这是错的：竖向列表只能靠
  *自己生成*候选来画，而生成候选要付出真实的功能代价。
  - 它**绕过了 `_main_complete`**，因此它覆盖的场景会失去候选**描述**、
    `list-colors` 着色、分组，以及 `matcher-list`——文档里那条模糊匹配**不适用于**生成的候选。
  - 只生成命令 / 函数 / 别名 / 内建、文件系统路径与 `cd` 最近目录。其余场景（git 子命令、
    ssh 主机、`--选项`、`sudo …`）会兜底回原生网格，于是**弹窗会在打字过程中变形**——很容易
    被误认为「又冒出一个列表」。
  - 超过终端宽度的候选会被截断（没有省略号）。
  没有删除任何东西：`SMART_MENU_SINGLE_COLUMN=true` 仍然是 v2.2.3 那个竖向列表。安装器现在
  会就此提问（默认**否**），并把代价写在问题里。
- `tests/e2e-tmux.sh` 增至 **41** 项。场景 10 按顺序断言单列契约——默认是网格（10a）、
  开启后每行一个（10b）、关掉后网格回归（10c）；10a 与 10c 正是让 10b 可失败、而非空过的
  前提。场景 11 走的是列表器开关的 BEFORE → OFF → BACK ON：只有这个结构才能让中间那一步
  有意义（没有「切回来」这一步，「零行」同样可以由「压根不补全了」满足），它还会断言行内
  灰字建议在交接后仍然存活。
- v2.1.6 的 A/B 基线是**实测**的、**不是按比例换算**的：**20/41**。在 v2.1.6 上既没有
  弹窗也没有这个开关，所以 10a/10b/10c 失败，场景 11 也大部分失败。该区域仍有 3 条通过，而
  **其中只有 1 条是真的**——行内灰字建议在交接后仍然存活（v2.1.6 同样有 `POSTDISPLAY`）。
  另外两条——10b 的「没有一行塞两个候选」与 11b 的「交接后我们不画列表」——是**空过**，因为
  那个版本根本不会画任何列表。能把这三种通过区分开，正是基线必须实跑、而不能从旧分数推出来
  的原因。
- `tests/test-menu.zsh`：144 → 183。场景 5 现在**直接驱动 `smart-lister` CLI**，对每一个
  被接受的拼写断言三处编码这份清单的地方保持一致。它们分别写在不同位置（归一化函数、
  「是否被识别」检查、以及 CLI），而且**已经漂移过**：CLI 接受 `on` 而识别函数不认——于是
  `smart-lister on` 成功、紧接着的 `smart-lister` 却自相矛盾；而 `no`/`false`/`0` 对两个
  辅助函数是 fzf-tab，在 CLI 里却落到状态输出。手抄一份拼写清单抓不到这种问题——上一轮正是
  这么漏掉的。`smart-doctor` 新的「已交接」结论在场景 13b 里被钉住，包括它的**误报**一侧
  （一个**确实已加载**的选择器必须能清除警报）。
- `tests/test-config.zsh`：39 → 43。新增场景 5 固化那个已经漂移过两次的值：5 份 README 里
  写明的单列默认值必须等于 `lib/config.zsh` 的实际默认值。
- 合计：**590 项断言**（9 个 zsh 套件共 532 项 + 安装器套件 58 项）；e2e **41/41**。

## [v2.2.3] - 2026-09-16

### 修复
- **`Delete` 键会留下行内残影。** 退格键早已被接管，但 `Delete`（`ESC [ 3 ~`）没有：
  调出历史补全后再按 Delete 删掉一个字符，上一条建议会**冻结**在屏幕上。现在 Delete 与
  退格键一样被接管（emacs / viins 两个键盘表），并在卸载时原样归还。
- **单列弹窗其实一直在按网格渲染。** 填充宽度写成了一行
  `local cols=... pad="$cols"`——而 `local` 命令的所有展开都发生在两个赋值**之前**，于是
  `pad` 是空串，`${(r...)…}` 按宽度 0 填充，列表自然还是多列，**代码看起来却是对的**。
  现在宽度按变量名传给填充（`${(r.cols.. .)...}`）。

### 新增
- **单列（垂直）实时弹窗**——`SMART_MENU_SINGLE_COLUMN`，默认 `true`。打字即时弹窗改为
  **每行一个候选**，不再使用 zsh 原生的多列网格。做法是直接生成候选（命令 / 函数 / 别名、
  文件系统路径、`cd ` 最近目录），并把每一条**显示字符串**填充**或截断**到恰好 `COLUMNS`
  宽——这在数学上只能容下一列。设为 `false` 即退回原生网格。
  - 为什么是「生成」而不是「截获」：把 `compadd` 换成函数后，某些 zsh 版本会**彻底不再添加
    候选**（已实测），那会让弹窗静默变空。
  - 输入会被转义后才送进 glob 引擎：此前输入的 `[` 会拼出模式 `[*`，而「坏模式」不是
    nomatch——它会**中断**生成器并在**每一次按键**都打印 `bad pattern:`。但开头的 `~/`
    刻意**不**转义，否则所有 `~/…` 候选都会消失。
  - 保留了兜底：生成器覆盖不到的场景（git 子命令、ssh 主机名、选项串）仍会跑你真正的补全。
- **`smart-doctor`**——把「还有谁能在屏幕上画出第二个候选列表」的指纹全部打印出来：
  `_main_complete` / `compadd` / `_complete` 是否仍是 zsh 原生入口，是否加载了
  zsh-autocomplete / zsh-autosuggestions / fzf-tab / 语法高亮，每个键盘表里 `Tab` 归谁，
  哪些 zstyle 能开启列表，以及本插件自身的状态——最后给一句结论。**只读**，所以在半坏掉的
  shell 里也能安全运行。
- **安装器的可选配置改为交互式。** fzf-tab、Tab 菜单、单列布局、最近目录、↑/↓ 历史搜索、
  zsh-vi-mode 与建议来源都会在安装时逐项询问，回答被写进所生成 `~/.zshrc` 的一个受管区块。
  `install.sh` 与 `install-entware.sh` 均已支持。
  - 该区块刻意位于**插件加载之前**：部分选项（尤其 `SMART_MENU_HISTORY_KEYS`）是在插件安装
    按键绑定的**那一刻**读取的，写在加载之后会被静默忽略。
  - fzf-tab 默认**关闭**（需主动勾选）；一旦启用，会强制关掉内置的可选择菜单——两者同开
    正是两个列表器抢同一块屏幕的由来。
  - `NONINTERACTIVE=1` 时全部取文档默认值。

### 变更
- **修正 `starship.toml` 模板。** 顶层 `format` 里写了 `[$user]($style)`，而 `($style)` 只在
  各 `[section]` 内部有效，导致**用户名被吞掉**。现在第一行为 `[$user] › $directory`，
  第二行为 `$character`。
- 安装器的 `.zshrc` 模板新增了受管的选项槽位；末尾那段「Optional:」注释换成了**没有**被做成
  问题的其余可调项。

### 测试
- `tests/test-menu.zsh`：109 → 144。新增场景 13b（`smart-doctor`）与场景 14（单列候选生成，
  以及单列不变式：每条显示字符串都恰好 `COLUMNS` 宽，且填充/截断绝不改到真正被插入的文本）。
- `tests/test-zle.zsh`：93 → 102。两个键盘表的 `Delete` 绑定、卸载时归还、以及每次按键都不得
  向 stdout 输出。
- `tests/test-config.zsh`：37 → 39。`SMART_MENU_SINGLE_COLUMN` 的默认值与用户覆盖。
- **`tests/test-installer-options.sh`（新增，54 项断言，bash）**——把安装器的选项机制抽出来，
  对临时文件驱动。它固化的正是源码里看不出来的那一条：受管区块必须落在**插件加载之前**，且
  重复运行必须幂等。它还会把每一项安装器默认值与 `lib/config.zsh` 对照——正是这条对照抓出了
  Tab 菜单默认值与实际发布值不一致。
- `tests/e2e-tmux.sh`：29 → 33。**10** 断言 6 个候选占 6 行、全部列出、且没有一行塞两个；
  **10b** 打开 `SMART_MENU_SINGLE_COLUMN=false` 并断言网格回归，以此证明 10 确实可能失败。
- 合计：**538 项断言**（9 个 zsh 套件共 484 项 + 安装器套件 54 项）；e2e **33/33**。

## [v2.2.2] - 2026-09-16

### 修复
- **`Tab` 之后按 `Enter` 现在会真正执行该行**，而不只是重绘。此前补全之后，第一次
  `Enter` 会被 accept-line widget 吞掉（它把补全当成仍「进行中」，只刷新显示），于是
  补全过的 `cd …` 需要**再按一次** `Enter` 才执行。现在该 widget 先清理自身状态，再直接
  调用 `zle .accept-line`。这是个**历史遗留缺陷**——在 v2.2.1 上可以复现。

### 新增
- **最近目录候选**（`lib/engine/recent.zsh`，`SMART_RECENT_PATHS`，默认 `true`）。补全
  `cd` / `pushd` / `chdir` 参数时，会把你**真正去过**的目录作为候选；并且在 `cd ` 后的
  **空词**上立即列出——这是空词唯一值得列表的场景。实现方式是把一个补全器前置到
  `zstyle ':completion:*' completer`，因此与你自己的补全链共存，`smart-recent off` /
  `smart-disable` 时干净移除。
- **只读。** 数据是 zsh 自带的最近目录数据库（`cdr` 与 `~[1]` 用的同一个），插件**从不
  写入**。`SMART_RECENT_PATHS_MAX`（默认 `20`）限制候选数量；`smart-recent status` 报告
  当前可用条目数。
- **`smart-recent on|off|toggle|status`** 运行时命令。

### 变更
- **模糊匹配只做文档说明，不自己实现。** 实时弹窗跑的就是你自己的补全系统，所以一条
  `zstyle ':completion:*' matcher-list` 已经自动生效——本插件**刻意不含**模糊匹配代码，
  自己加只会和 compsys 打架。README 的「可选增强」一节给出了要设的那一行。

### 测试
- `tests/test-recent.zsh`（38 项断言）：`cd` 参数位置判定、数据库解析（空格 / 引号 / XDG
  路径 / 失效条目），并**固化一条回归**——补全器是通过 `zstyle ':completion:*' completer`
  接入的，**不是** `$completer` 数组（那个变量在 zsh 里根本不存在，之前代码「看起来接好了」
  其实什么都没做）。
- `tests/e2e-tmux.sh`：新增 **8b**（Tab 后按 Enter 会执行该行）与 **9**（`cd ` 列出最近
  目录，Tab 补全出完整路径）。共 29 项断言；**在 v2.1.6 上为 17/29**。

## [v2.2.1] - 2026-09-16

### 修复
- **实时弹窗不再吞按键。** 之前用 `LISTMAX=-1` 作用域包裹列表调用（用来压掉 zsh 的
  「是否显示全部 N 项（M 行）」提示），会破坏 ZLE 的下一次输入读取：输入 `git status`
  真正进入缓冲区的是 `gitstatus`，shell 执行的是**错命令**。现在**完全不碰 `LISTMAX`**，
  改为对超大候选列表直接不绘制（`SMART_MENU_MAX_MATCHES`，默认由「不封顶」改为 `100`）
  ——这是实测在「短候选列表」与「1200 项目录」两种场景下都干净的唯一设置。
- `smart-menu status` 与 tick 调试日志现在能区分「低于下限」与「超过上限」，此前两者都
  被写成 `below min`，会把排查方向带偏。

### 新增
- **`SMART_SUGGEST_STRATEGY`**（`history` | `history,completion`，与
  zsh-autosuggestions 同名）。加上 `completion` 后，灰字建议可以来自补全系统——路径、
  选项、子命令等历史里没有的内容，做法是取光标处单词的「无歧义前缀」。
- **具名可改键 widget**：`smart-accept-suggestion`、`smart-accept-word`、
  `smart-execute-suggestion`、`smart-suggestion-toggle`。
- **`SMART_MENU_HISTORY_KEYS`**（默认 `false`）：设为 `true` 时，行内非空则 ↑/↓ 按前缀
  搜索历史（zsh-autocomplete 的招牌行为），行内为空则退回原生历史导航。

### 测试
- `tests/e2e-tmux.sh` 新增真终端下的**缓冲区完整性**断言：逐字输入不得丢字符，且**真正
  被执行的命令**就是输入的那条。此前的用例只断言「列表有没有画出来」，因此弹窗在破坏
  每一条命令行的同时测试仍然是全绿的。

## [v2.2.0] - 2026-09-15

这个版本终于交付了本插件存在的**全部理由**：把 `zsh-autocomplete` +
`zsh-autosuggestions` 的两个功能半边，在**一个插件里**以原生方式实现。

### 新增
- **打字即弹候选菜单**（`lib/engine/menu.zsh`）：每编辑一次缓冲区就计算并绘制候选
  列表，于是补全在你打字时就出现——无需按 `Tab`。基于用户自己的 compsys 之上，通过
  私有补全 widget（`zle -C ... list-choices`）实现：其 completer 读取
  `compstate[nmatches]` 决定列表是否绘制，从不改动 `compinit`。总开关 `SMART_MENU`，
  运行时 `smart-menu on|off|status`。
- **行内灰字与候选列表共存。** 列表重绘与 `POSTDISPLAY` 争用同一块屏幕区域，因此顺序
  固定：先画灰字，再跑列举，之后绝不重绘。单个候选（`SMART_MENU_MIN_MATCHES`）会撤掉
  列表、让灰字接管。
- **自适应节流**（`SMART_MENU_SLOW_MS` / `SMART_MENU_COOLDOWN_KEYS`，默认关闭）：耗时
  达到阈值的列举会换来一段冷却，留给**持续**很贵的补全。默认关闭，因为实测唯一的尖峰
  是补全子系统加载时的一次性 ~180ms，为它节流只会让会话里第一条 `git <TAB>` 丢掉弹窗，
  却只省下那一次 180ms。
- **`SMART_MENU_DEBUG=/path/to/log`**：每次 tick 的决策（闸门是否拒绝 / 冷却是否吞掉该
  次编辑 / 命中几个候选 / 实际花了多少毫秒）追加写一行。"没弹出来" 否则与 "只有一个候选、
  于是灰字接管" 无法区分。
- **`Alt+→` 接受一个词**：接受行内建议中的一个词（随后重新建议剩余部分）。无建议可接受时
  降级为 zsh 自带的 `forward-word`。

### 修复
- **严重 — 全新会话里右箭头没反应**：只绑了 `ESC [ C`（CSI），但 `TERM=xterm-256color`
  的 `kcuf1` 是 `ESC O C`（*应用光标键* 形式），且 ZLE 会把终端切进该模式。于是该键落到
  zsh 自带的 `forward-char`，建议永远不被接受，而灰字清晰可见——典型的"灰字在、箭头死"。
  现在绑定所有箭头编码，序列列表由 `terminfo` 加 CSI/SS3 兜底构建。
- **严重 — 同款终端下 `Alt+→` 也死**：`Alt` 本质就是"先发 `ESC` 再发方向键"，因此继承了
  多编码问题。旧代码只绑了 `ESC [ 1 ; 3 C`（xterm）和 `ESC ESC [ C`；处于应用光标键模式的
  终端发送 `ESC ESC O C`，它未绑定，会把字面 `^[` 塞进缓冲区。`Alt` 形式现在由"给每个
  普通箭头编码前缀 `ESC`"**派生**而来，二者不会再漂移。
- **绑定捕获误解析原始字节序列**：`_smart_evt_binding`（`lib/event/zle.zsh`）和
  `_smart_current_binding`（`lib/engine/native.zsh`）用文本匹配去剥键名，但 `bindkey` 回显
  键名恒为 `^X` 记法——对原始字节序列（如 terminfo 的 `kcuf1`）匹配失败，于是把*键文本*存
  成了 widget 名。保存的原始值被污染，解绑时键永远无法还原。两个解析器现在统一取 `bindkey`
  输出的末字段。
- **循环内 `local` 泄漏到 stdout**（`lib/event/zle.zsh`）：zsh 5.9 在 `local` 声明第二次
  执行时会打印 `var='<旧值>'`，而写在迭代 >1 次的循环体内的 `local` 正是如此。那段输出在 ZLE
  widget 路径里直接落到命令行。现在所有循环变量都在函数顶部一次性声明；`tests/test-zle.zsh`
  断言 bind/unbind 循环保持静默。
- **`zmodload -F` 的 feature 前缀**：`EPOCHREALTIME` 和 `terminfo` 是*参数*，必须用
  `p:EPOCHREALTIME` / `p:terminfo` 请求。被拒的 `b:` 请求让两者都未定义——静默禁用了节流与
  来自 terminfo 的箭头序列。已加回归测试。
- **关联数组引号下标**：`assoc["km|seq"]=x` 会把引号存进键名，导致 `assoc[km|seq]` 取不到。
  现在先用变量拼键、再用无引号下标索引（与 `lib/state.zsh` 已有的规则一致）。
- **安装器**：说明*为何*移除 `zsh-autocomplete` / `zsh-autosuggestions`（两种行为都已原生
  实现），而不再静默删除。

## [v2.1.6] - 2026-09-15

### 修复
- **严重 — 可打印 ASCII 输入被吞**：`_smart_evt_binding` 从 `bindkey -R "^@-^_"` 范围查询
  捕获到伪 widget `undefined-key` 并把可打印键发给它，于是 `zle undefined-key`（空操作）吃掉
  了每个 ASCII 按键。CJK/UTF-8（字节 >= 0x80，在重绑范围外）仍经真正的 `self-insert` 插入——
  因此"中文能打、英文打不出"。捕获现在把 `undefined-key` 归一为未绑定以使用 `self-insert`；
  `_smart_evt_dispatch` 也加守卫；`_smart_current_binding`（native.zsh）同样加固。`tests/test-zle.zsh`
  已加回归测试。
- **键位捕获加固**：self-insert 的原始 widget 现在硬编码而非范围探测（范围查询在我们的绑定前
  报 `undefined-key`、绑定后报我们自己的 wrapper，两者都不是可用原始值）。捕获由专用标志
  `_SMART_EVT_CAPTURED` 守卫，而非某个 `ORIG_*` 变量的内容，因此陈旧或手设的
  `_SMART_EVT_ORIG_SELF_*` 再也无法跳过整段捕获（那会静默丢掉原生 Tab 绑定及所有其他原始值）。
  捕获探针额外拒绝记录任何 `_smart_*` / `smart-*` widget，因此重新捕获绝不会派发回我们自己的
  wrapper。
- **安装器 — 受管块标记从未写出**：`build_zsc_integration` 在 bash 脚本里用了 `print -r --`
  （zsh 内建），调用静默失败，`# >>> zsh-smart-complete integration (managed) >>>` / `# <<< ... <<<`
  标记行被丢弃。没有 BEGIN 标记，`_upsert_zsc_block` 永远匹配不上，于是每次重装都追加重复块而非
  原地替换。现改用 `printf '%s\n'`。

### 新增
- **可选 `zsh-vi-mode`（opt-in，默认 NO）**：vi 键位确实有用，但本插件独占整张 keymap 且每次
  line-init 都重初始化 ZLE，这正是搞坏其他插件键位的经典做法——因此绝不隐式安装。用户选择时，
  安装器克隆它并写入一块：在 zsh-smart-complete *之前*加载，并通过 `zvm_after_init` /
  `zvm_after_lazy_keybindings` 重新套用我们的 widget。
- **安装器在流程中安装 fast-syntax-highlighting**（`_ensure_zinit_plugin
  zdharma-continuum/fast-syntax-highlighting`），完整组合与插件两条路径都装，不再依赖 Zinit 在首次
  启动自动克隆。

### 变更
- **安装器 .zshrc 策略**：完整推荐 `.zshrc` 模板只在本次（重新）安装了完整栈（Phase 0/5 组合）时
  才推荐；仅插件安装现在只管理带标记的 `zsh-smart-complete` 块（幂等 upsert，绝不覆盖整个文件）。

## [v2.1.5] - 2026-09-15

### 修复
- **安装器 — p10k/OMZ 清理器**：`_remove_p10k` / `_remove_omz` 现在还会删除 Zinit 克隆的插件目录
  （`$ZINIT_PLUGINS_DIR` 下的 `romkatzen---powerlevel10k`、`OMZ::ohmyzsh---ohmyzsh`），因此选非
  p10k/OMZ 组合能彻底清除下次启动会重新加载的陈旧残留。`.bak.*` 产物直接删除，避免级联备份。
- **安装器 — `.zwc` 字节码**：插件更新路径（`git reset --hard`）现在也会删除 Zinit 编译的 `*.zwc`
  缓存，于是引擎修复在更新后真正生效（此前加载的是陈旧编译代码）。
- **引擎 — 全局泄漏**：`lib/engine/suggest.zsh` 里的 `cmd_cwd` / `cmd_host` / `cmd_exit` 现在声明为
  `local`（此前每次按键都泄漏成全局变量）。
- **引擎 — 历史封顶**：`_SMART_CMDS` 现在封顶到 `SMART_SUGGEST_HISTORY_LIMIT`（默认 20000）；当
  `SMART_HISTORY_REBUILD_EVERY=0` 关闭周期重建时，最旧条目被丢弃且 bucket/assoc 槽保持同步。

## [v2.1.4] - 2026-09-12

### 修复
- fzf 安装被静默跳过（无交互）；安装进度显示两次（Phase 0/5 然后 Phase 1-4）。加了 `RAN_COMBO`
  守卫并让 fzf 提示改为交互式。

## [v2.1.3] - 2026-09-11

### 修复
- 每个 y/N 提示都崩溃 `read: -: invalid option`——`IFS=$'\n\t'` 破坏了 `read $_args`；改为
  `read "$@"`。

## [v2.1.2] - 2026-09-10

### 修复
- 安装器提示现在阻塞直到用户确认每一步；冲突插件 `.bak.*` 级联修复（主目录只备份一次）；陈旧插件
  现在真正通过 `git fetch --depth 1` + `git reset --hard` 更新。

## [v2.1.1] - 2026-09-09

### 新增
- **zsh 重装提示**：zsh 已安装时，提示用户通过 brew（macOS）或 apt（Debian/Ubuntu）重装/升级。
- **fast-syntax-highlighting**：通过 `.zshrc` 模板里的 `zinit light
  zdharma-continuum/fast-syntax-highlighting` 加载（Zinit 启动时自动克隆）；不由 install.sh 直接管理。
- **i18n 消息**：在 zh-CN、zh-TW、ja、ko、en 中新增 `prompt.zsh_reinstall`。

### 变更
- **Phase 0**：完整组合安装现在包含 zsh 重装逻辑；fast-syntax-highlighting 由 Zinit 经 `.zshrc` 模板加载。
- **Phase 1-3**：恢复 starship/atuin/zinit 提示上的 `SKIP_DEPS` 守卫。

### 修复
- zsh 重装提示使用正确的 brew/apt 回退逻辑。

## [v2.1.0] - 2026-09-08

### 新增
- **Phase 0/5**：完整推荐组合安装（zsh + fzf + starship + atuin + zinit + zsh-smart-complete）。
- **交互式备份清理**：提示用户清理冲突插件残留（`.cache/p10k-*`、`.cache/zsh*`、
  `.local/state/zsh-autocomplete` 等）。
- **fzf 自动安装**：包管理器不可用时从 GitHub 克隆。

### 变更
- 当 `SKIP_DEPS!=1` 且 `NONINTERACTIVE!=1` 时，安装器现在先跑 Phase 0；Phase 0 被跳过时 Phase 1-3 作为回退。

## [v2.0.6] - 2026-08-26

### 修复
- 发布流程：tar/zip 前先 stage 文件，避免 "file changed" 竞争。

## [v2.0.5] - 2026-08-26

### 修复
- `mirror.chosen` 消息中的错误变量替换。
- 清理旧的 `.bak.*` 残留。

## [v2.0.3] - 2026-08-26

### 修复
- i18n：翻译剩余所有中文状态消息。
- 修复 SSH 输入问题。

## [v2.0.2] - 2026-08-26

### 修复
- i18n：镜像选择菜单现已完全国际化。

## [v2.0.1] - 2026-08-26

### 修复
- 解决 3 个安装器问题：i18n 组合菜单、OMZ/p10k 默认选是、starship.toml 转义。

## [v2.0.0] - 2026-08-25

### 新增
- 引擎与安装器重构。
- O(bucket) 前缀索引。
- de-subShell 评分。
- 实时增量索引。
- Zsh 检测。
- OMZ/p10k 组合选择器。
- Entware 安装器。
- 停止每次按键的 stdout 泄漏（曾搞乱 ZLE 行编辑器）。

## 更早的版本

```
v0.1.0  ZLE 前端、历史索引、建议引擎
   │
v0.1.3  确定性排序（衰减 + 频率 + CWD 加成）
   │
v0.2.0  Atuin SQLite 后端（host / exit / CWD 感知排序）
   │
v1.0.0  GA — 稳定公共 API、CI/CD、自动发布
   │
v2.0.0  引擎与安装器重构 — O(bucket) 前缀索引、de-subShell 评分、
        实时增量索引、Zsh 检测、OMZ/p10k 组合选择器、Entware 安装器
   │
v2.1.0  Phase 0 完整组合安装（zsh + fzf + starship + atuin + zinit +
        zsh-smart-complete），交互式备份清理
   │
v2.1.6  修复可打印 ASCII 输入（undefined-key）、捕获加固、
        fast-syntax-highlighting、组合感知 .zshrc、opt-in zsh-vi-mode
   │
v0.5.x  smart-shell-engine（Rust / Go，经 IPC）（未来，opt-in）
   │
v2.0    Smart Shell — 完整独立 shell（未来）
```
