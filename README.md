# PowerShell 配置 + AI 命令预测（AIPredictor）

一套自用的 PowerShell 7 配置：**一个不会把终端搞崩的稳定 profile**，加上一个**真正能用的 AI 命令预测器**——
输入中文按 `Tab`，AI 直接给出可执行的 PowerShell 命令。

> 当前稳定版 **v1.2.0** ｜ 适用：Windows + PowerShell 7.2 及以上 ｜ 实测：PowerShell 7.6.6 + PSReadLine 2.4.5 + oh-my-posh 23.15.3

---

## 目录

- [仓库里有什么](#仓库里有什么)
- [快速开始](#快速开始)
- [用法：三种触发方式](#用法三种触发方式)
- [AIPredictor 配置](#aipredictor-配置)
- [Profile 配置](#profile-配置)
- [工作原理](#工作原理)
- [排错](#排错)
- [版本与回退](#版本与回退)

---

## 仓库里有什么

| 路径 | 说明 |
| --- | --- |
| `Microsoft.PowerShell_profile.ps1` | 主配置文件（稳定版）：oh-my-posh 随机主题、系统代理→环境变量、命令历史、模块加载、接入 AI 预测器 |
| `Modules/AIPredictor/AIPredictor.psm1` | AI 预测器模块：编译并注册 C# 预测器、绑定 `Alt+P`、接管 `Tab`、提供 `Test-AIPredictor` 自检 |
| `Modules/AIPredictor/src/AIPredictorSource.cs` | 预测器本体（C#，实现引擎的 `ICommandPredictor`）：缓存 + 异步请求 + 输出清洗 |
| `Modules/AIPredictor/config.example.json` | 配置模板。复制为 `config.json` 并填 API Key（`config.json` 含密钥，已被 .gitignore 排除） |
| `Scripts/Clean-OldModules.ps1` | 清理 `Modules` 目录里旧版本模块的小脚本 |
| `powershell.config.json` | PowerShell 实验特性开关（PSFeedbackProvider / PSCommandNotFoundSuggestion） |
| `symboliclink/` | 早期笔记：尝试用符号链接把命令历史备份到 OneDrive |
| `powershell_random_theme_oh_my_posh/` | 早期的随机主题 profile（历史版本，留作参考） |

---

## 快速开始

### 1. 拿到文件

```powershell
git clone https://github.com/zhangjiancai/powershell_demo.git D:\src\powershell_demo
```

把 profile 和模块放进 PowerShell 7 的配置目录（`$PROFILE` 所在目录，通常是 `%USERPROFILE%\Documents\PowerShell`）：

```powershell
Copy-Item D:\src\powershell_demo\Microsoft.PowerShell_profile.ps1 $PROFILE
Copy-Item D:\src\powershell_demo\Modules\AIPredictor "$(Split-Path $PROFILE)\Modules\" -Recurse
```

> 作者的用法更直接：`%USERPROFILE%\Documents\PowerShell` 本身就是这个仓库的工作副本。

### 2. 配置 API Key

```powershell
$dir = "$(Split-Path $PROFILE)\Modules\AIPredictor"
Copy-Item "$dir\config.example.json" "$dir\config.json"
notepad "$dir\config.json"      # 填 ApiKey
```

不想写进文件也可以，用环境变量 `DEEPSEEK_API_KEY` 或 `LLM_API_KEY`。

### 3. 重开终端并自检

```powershell
Test-AIPredictor
```

各项显示绿色即可用。

---

## 用法：三种触发方式

| 方式 | 操作 | 说明 |
| --- | --- | --- |
| **Tab（推荐）** | 输入中文 → 按 `Tab` | 菜单第一项就是 AI 给出的整行命令，回车/Tab 采用（同步等待约 1 秒）。普通命令输入仍然走原生补全 |
| `Alt+P` | 输入后按 `Alt+P` | 立即问 AI 并把建议写进命令行，**不会自动执行** |
| 行内灰字 | 出现灰字后按 `→` | 附带效果：PSReadLine 只在缓冲区变化时查询预测器，AI 答案通常晚到，所以不稳定 |
| 脚本调用 | `Get-AIPredictorSuggestion -InputText "列出最大的文件"` | 直接返回字符串，可嵌进自己的脚本 |

其它命令：

```powershell
Test-AIPredictor          # 自检：注册状态 / 预测源 / 快捷键 / Tab 接管 / 真实 API 请求 / 日志尾部
Get-AIPredictorStatus     # 当前状态一览
Unregister-AIPredictor    # 临时关掉预测器（撤销注册与快捷键）
Register-AIPredictor      # 再打开
```

---

## AIPredictor 配置

`config.json`（从 `config.example.json` 复制）：

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `Model` | `deepseek-chat` | 模型名 |
| `Endpoint` | `https://api.deepseek.com/chat/completions` | 任何 OpenAI 兼容接口都可以 |
| `ApiKey` | 空 | 也支持环境变量 `DEEPSEEK_API_KEY` / `LLM_API_KEY` |
| `TimeoutSeconds` | 8 | 单次请求超时 |
| `MinInputLength` | 4 | 短于该长度不打扰 AI |
| `DebounceMs` | 800 | 两次请求的最小间隔 |
| `MaxTokens` | 200 | 生成上限 |
| `Temperature` | 0.2 | 越低越稳定 |
| `MaxCacheEntries` | 200 | 结果缓存条数 |
| `MaxSuggestionLength` | 500 | 建议最大长度 |
| `Hotkey` | `Alt+P` | 留空则不绑定 |
| `EnableTabCompletion` | `true` | 中文输入时接管 Tab |
| `EnableLog` | `true` | 写运行日志，排查问题用 |
| `LogPath` | `ai_predictions.log` | 日志位置（超过 1 MB 自动截断） |
| `SystemPrompt` | 空 | 自定义系统提示词 |

换成别的服务商只需改三行，例如阿里云百炼：

```json
"Model": "qwen3-max",
"Endpoint": "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
"ApiKey": "sk-你的百炼Key"
```

---

## Profile 配置

路径写在 profile 顶部的“配置区”，也可以用环境变量覆盖：

| 环境变量 | 作用 |
| --- | --- |
| `POSH_PROFILE_QUIET=1` | 启动时不打印汇总信息 |
| `POSH_PROFILE_FORCE_INTERACTIVE=1` | 强制按交互式终端加载（排错用） |
| `OHMYPOSH_EXE=<路径>` | 覆盖 oh-my-posh 可执行文件位置 |
| `OHMYPOSH_THEMES=<目录>` | 覆盖主题目录 |
| `OHMYPOSH_THEME=<json>` | 固定主题（不设置则每次随机） |
| `AIPREDICTOR_SKIP_AUTOREGISTER=1` | 不自动注册 AI 预测器 |

profile 的设计原则：

1. **绝不 `exit`** —— 任何一项配置失败都不会关闭终端窗口；
2. **分块 try/catch** —— oh-my-posh、代理、模块各自独立，互不影响；
3. **只在交互式终端做交互的事** —— 管道 / 重定向 / CI 下自动跳过 PSReadLine、WinGet 等；
4. 路径集中且可用环境变量覆盖，非交互式会话启动 0 报错。

---

## 工作原理

- AI 预测走 **PowerShell 7.2+ 引擎的「命令预测器」子系统**（`ICommandPredictor`）：模块把预测器注册进 `SubsystemManager`，PSReadLine 打开 Plugin 预测源后由引擎回调。
- **为什么用 C#**：PowerShell 类也能实现该接口，但返回值 `SuggestionPackage` 是结构体，PS 类 → CLR 接口的封送会丢内容（实测引擎只收到空包）。
- **为什么不直接做“边打边提示”**：PSReadLine 只在**缓冲区变化**时查询预测器，而 AI 答案要 1 秒左右才到，那时已经没有触发点，行内灰字基本不会出现——这就是“打了没反应”的原因。所以主力改成 **Tab（同步、按需）**，`Alt+P` 兜底；行内预测保留，命中缓存时会显示。
- 预测器内部是**缓存 + 尾沿防抖 + 后台线程**：按键路径永远立即返回，不会卡住输入。

---

## 排错

先跑：

```powershell
Test-AIPredictor
```

| 症状 | 处理 |
| --- | --- |
| 按 Tab 没有 AI 建议 | 确认输入**含中文字符**（只对自然语言接管）；确认 `EnableTabCompletion: true`；看自检输出 |
| API 请求失败 | 自检会打印确切错误；检查 Key、Endpoint，以及**代理**（`HTTP_PROXY` 会影响请求） |
| 行内灰字不出现 | 属正常现象，见[工作原理](#工作原理)，请用 Tab 或 Alt+P |
| 改了 `AIPredictorSource.cs` 不生效 | 删除 `Modules/AIPredictor/bin` 后重开终端，会自动重新编译（缓存文件名带源码哈希） |
| 启动报 `Unable to find type [AIPredictor...]` | 编译缓存异常：删 `bin` 目录后重开终端 |
| 想彻底关掉 | `Unregister-AIPredictor`，或设 `$env:AIPREDICTOR_SKIP_AUTOREGISTER=1` |

日志在 `Modules/AIPredictor/ai_predictions.log`，每次查询、每次请求、每次错误都有时间戳。

---

## 版本与回退

| tag | 内容 |
| --- | --- |
| `v1.0.0` | 稳定版 profile：移除全部 `exit`、按会话类型跳过交互功能、删除历史版本文件 |
| `v1.1.0` | AIPredictor 真正可用：改用引擎预测子系统（C#）+ `Alt+P`；API 修正为 OpenAI 兼容模式 |
| `v1.2.0` | 新增 Tab 出 AI 建议（修掉“真实操作没反应”）、修掉 4 个启动报错、API 换成 DeepSeek、新增自检命令 |

回退单个文件：

```powershell
git checkout v1.2.0 -- Microsoft.PowerShell_profile.ps1
```

---

## 依赖

- **PowerShell 7.2+**（引擎预测子系统要求）
- **PSReadLine 2.2+**
- oh-my-posh（可选，用于提示符主题）
- Az.Tools.Predictor、Microsoft.WinGet.CommandNotFound（可选，profile 会自动检测并跳过缺失项）

## 说明

个人自用配置，随意取用。
