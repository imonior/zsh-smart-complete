# zsh-smart-complete

> 一个现代化的智能补全和建议层，专为 Zsh 设计。
> 作为未来独立 shell 的前端引擎。
>
> **v2.2.1** — 最新发布：修复实时弹窗吞掉按键的缺陷；灰字建议可在历史之外回落到补全系统；新增具名 widget 与可选的 ↑/↓ 历史搜索。

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-TW.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md)

## 状态

| 渠道 | 状态 |
| ------ | ------ |
| 构建与测试 (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| 发布 | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| 版本 | 2.2.1 |

## 为什么选择我们

同时替换 `zsh-autocomplete` 和 `zsh-autosuggestions`，采用简洁的模块化架构，为演变为独立 shell 而设计。

- **两部分合为一体（v2.2.0）** — 打字时**立即弹出候选列表**（zsh-autocomplete 的行为），同时保留行内灰字建议，`→` 全量接受、`Alt+→` 一次接受一个词（zsh-autosuggestions 的行为）。同一个插件、同一套键位、两个通道，这正是"两个插件互相冲突"的根本解法。
- **零外部依赖** — 核心插件自包含；可选 Atuin 增强。
- **箭头键全编码绑定** — `ESC [ C` 与 `ESC O C`（应用光标键模式，`TERM=xterm-256color` 下终端实际发送的形式）都绑定，不会出现"灰字在、右箭头没反应"。
- **与语法高亮兼容** — 使用 `#zsh-smart-complete:suggestion` 标记，不覆盖其他 highlighter。

## 架构

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
        history/history         (用户 compinit)
                                       │
                                   engine/menu
                              （打字即弹候选列表）
               │
      zsh fc   │   atuin (可选)   │   smart-engine (未来)
               └───────────────────┴───────────────────┘
                           │
                     display/
                 region_highlight
```

## 快速开始

### 前置条件

让 Zsh 本身拥有 `compinit`：

```zsh
export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=1000000
export SAVEHIST=1000000
setopt appendhistory sharehistory histignorealldups

autoload -Uz compinit
compinit
```

### 安装

> ⚠️ 本插件同时替换 `zsh-autocomplete` 和 `zsh-autosuggestions`。

#### 方式 A — 一键安装器（推荐）

```zsh
bash <(curl -fsSL https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)
```

#### 方式 B — Zinit（手动）

```zsh
zinit light imonior/zsh-smart-complete
```

#### 方式 C — 手动克隆

```zsh
git clone https://github.com/imonior/zsh-smart-complete.git ~/.zsh-smart-complete
echo 'source ~/.zsh-smart-complete/zsh-smart-complete.plugin.zsh' >> ~/.zshrc
```

#### 国内代理加速

```zsh
SMART_INSTALL_GH_MIRROR=https://ghproxy.net/ bash -c "$(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/imonior/zsh-smart-complete/main/install.sh)"
```

## 配置

在加载插件之前设置以下变量：

```zsh
# 主开关
: ${SMART_ENABLED:=true}
# 引擎
: ${SMART_SUGGEST:=true}
: ${SMART_COMPLETE:=true}
: ${SMART_SUGGEST_STRATEGY:=history}  # history | history,completion（completion 还会用补全系统作建议来源）
# 历史后端：zsh | atuin | smart-engine（未来）
: ${SMART_HISTORY_BACKEND:=zsh}
# 界面
: ${SMART_INLINE:=true}
: ${SMART_SUGGEST_COLOR:=fg=8}

# 打字即弹候选列表（zsh-autocomplete 那一半）
: ${SMART_MENU:=true}
: ${SMART_MENU_MIN_PREFIX_CMD:=2}     # 命令行首词至少几个字符才列
: ${SMART_MENU_MIN_PREFIX:=1}         # 参数词至少几个字符才列（0 = 空格后也列）
: ${SMART_MENU_MIN_MATCHES:=2}        # 候选少于这个数就不列（单个候选由灰字承担）
: ${SMART_MENU_MAX_MATCHES:=100}       # 候选多于此数就不列（既避开超大目录，也避开 zsh 的「是否显示全部 N 项」提示）
: ${SMART_MENU_MAX_PREFIX:=64}
: ${SMART_MENU_HISTORY_KEYS:=false}  # true = 行内非空时 ↑/↓ 按前缀搜索历史
# 节流：默认关闭。实测每次列举只要 10~30ms，没什么可降的；
# 这个开关是留给「持续很贵」的补全的。开启后，耗时 ≥ SLOW_MS 的列举
# 会换来 COOLDOWN_KEYS 次跳过。注意：被跳过的那次按键不会重绘，
# 屏幕上的候选列表会消失——这正是默认设为 0 的原因。
: ${SMART_MENU_SLOW_MS:=250}
: ${SMART_MENU_COOLDOWN_KEYS:=0}

# 排查用：设成文件路径后，每次 tick 的决策（被闸门拒绝 / 被冷却吞掉 /
# 命中几个候选 / 花了多少毫秒）都会追加写进去。"没弹出来"到底是
# 哪种原因，屏幕上分不出来，这个日志能。
: ${SMART_MENU_DEBUG:=}
```

同时提供具名 widget，可以像 `zsh-autosuggestions` 那样自行改键：
`smart-accept-suggestion`（整句接受，默认绑 →）、`smart-accept-word`（接受一个词，
默认绑 Alt+→）、`smart-execute-suggestion`（接受并执行该行）、
`smart-suggestion-toggle`（开关灰色建议）。设为 `SMART_MENU_HISTORY_KEYS=true` 后，
行内非空时 ↑/↓ 会按前缀搜索历史——默认关闭，因为这两个键的使用习惯很深。

## 运行时命令

```zsh
smart-status      # 打印当前状态 + 配置
smart-disable     # 禁用插件
smart-enable      # 重新启用
smart-reindex     # 强制重建历史索引
smart-menu on     # 开启打字即弹候选列表
smart-menu off    # 关闭（行内灰字建议不受影响）
smart-menu status # 查看菜单配置与上次列举结果
```

## 卸载

```zsh
rm -rf ~/.zsh-smart-complete
```

## 版本历史

请见 [CHANGELOG](./CHANGELOG.zh-CN.md) 获取完整历史。GitHub Release 的发布说明即从这些多语言 CHANGELOG 文件（en / zh-CN / zh-TW / ja / ko）提取。

## 测试

```zsh
zsh tests/test-config.zsh
zsh tests/test-history.zsh
zsh tests/test-suggest.zsh
zsh tests/test-ranking.zsh
zsh tests/test-atuin.zsh
zsh tests/test-zle.zsh
zsh tests/test-menu.zsh
zsh tests/test-integration.zsh
```

**测试汇总 (v2.2.1)：** 8 个测试文件共 393 项全部通过，0 失败。

端到端（真实 ZLE 键位）验证用 tmux `capture-pane` 读**真实屏幕**完成，
23 项断言全绿，覆盖"打字即弹列表""候选收窄时列表仍在""单候选让位给灰字"
"右箭头两种编码都能接受""`Alt+→` 三种编码都只接受一个词（用 `echo alpha beta`
探针，以命令输出判定缓冲区内容，而非回显的行）""开关往返""Tab 补全仍可用"。
脚本随仓库提供（无 `tmux` 时自动跳过）：

```zsh
./tests/e2e-tmux.sh                              # 23 项断言
./tests/e2e-tmux.sh /tmp/zsc-v216               # 对旧版本做 A/B
```

同一套断言在 v2.1.6 上过 16/23——即"打字即弹菜单"当时确实不存在。
本版 e2e 新增「缓冲区完整性」断言：逐字输入后提示符行必须与键入内容完全一致，
并以**真正执行的命令**的输出交叉验证——因为「每画一次候选列表就吞掉一个按键」
这类静默丢键，能骗过所有「只看屏幕」的检查。

方法沉淀在技能 `headless-pty-zle-verify`。

## 许可证

MIT — 见 [LICENSE](./LICENSE)。
