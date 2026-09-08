# zsh-smart-complete

> 一个现代化的智能补全和建议层，专为 Zsh 设计。
> 作为未来独立 shell 的前端引擎。
>
> **v2.1.1** — 最新发布：zsh 重装提示、zsh-syntax-highlighting 插件、完整 Phase 0 组合安装。

## 状态

| 渠道 | 状态 |
| ------ | ------ |
| 构建与测试 (CI) | [![CI](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/ci.yml) |
| 发布 | [![Release](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml/badge.svg)](https://github.com/imonior/zsh-smart-complete/actions/workflows/release.yml) |
| 版本 | 2.1.1 |

## 为什么选择我们

同时替换 `zsh-autocomplete` 和 `zsh-autosuggestions`，采用简洁的模块化架构，为演变为独立 shell 而设计。

- **零外部依赖** — 核心插件自包含；可选 Atuin 增强。
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
# 历史后端：zsh | atuin | smart-engine（未来）
: ${SMART_HISTORY_BACKEND:=zsh}
# 界面
: ${SMART_INLINE:=true}
: ${SMART_SUGGEST_COLOR:=fg=8}
```

## 运行时命令

```zsh
smart-status      # 打印当前状态 + 配置
smart-disable     # 禁用插件
smart-enable      # 重新启用
smart-reindex     # 强制重建历史索引
```

## 卸载

```zsh
rm -rf ~/.zsh-smart-complete
```

## 版本历史

| 版本 | 变更说明 |
| ------ | --------- |
| v2.1.1 | zsh 重装提示、zsh-syntax-highlighting 插件、恢复 SKIP_DEPS 守卫 |
| v2.1.0 | Phase 0 完整组合安装、交互式备份清理 |
| v2.0.6 | 修复发布流程文件竞争问题 |
| v2.0.5 | 修复 mirror.chosen 消息替换错误 |
| v2.0.3 | i18n 完整翻译、SSH 输入修复 |
| v2.0.2 | 镜像选择菜单国际化 |
| v2.0.1 | 修复 3 个安装器问题 |
| v2.0.0 | 引擎和安装器重构 |
| v1.0.0 | GA — 稳定公共 API、CI/CD、自动发布 |

## 测试

```zsh
zsh tests/test-config.zsh
zsh tests/test-history.zsh
zsh tests/test-suggest.zsh
zsh tests/test-ranking.zsh
zsh tests/test-atuin.zsh
zsh tests/test-zle.zsh
zsh tests/test-integration.zsh
```

**测试汇总 (v2.1.1)：** 7 个测试文件共 248 项全部通过，0 失败。

## 许可证

MIT — 见 [LICENSE](./LICENSE)。
