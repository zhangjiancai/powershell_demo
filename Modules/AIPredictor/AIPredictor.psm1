#Requires -Version 7.2
# ========================================================================
#  AIPredictor.psm1 —— AI 命令预测（PowerShell 引擎子系统 ICommandPredictor）
#
#  原理：
#    PowerShell 7.2+ 的引擎有“命令预测器”子系统；PSReadLine 打开 Plugin 预测源后
#    会调用注册进来的预测器。本模块把 C# 写的 AIPredictorSource（src\AIPredictorSource.cs）
#    编译并注册进去，于是你输入自然语言时，行内就会出现 AI 给出的命令建议。
#
#  三种用法：
#    1) 按 Tab    ：输入自然语言（中文整句，或英文整句如 "list the largest files"）后按 Tab，
#                   菜单第一项就是 AI 给出的整行命令，回车/Tab 采用（推荐）。
#                   命令编辑（./xxx、git xxx、带路径/参数的输入）不会被接管，原生补全照旧。
#    2) Alt+P     ：立即问 AI 并把建议写进命令行（默认 Alt+P，可在 config.json 改）。
#                   AI 返回多行脚本时也由它整段插入（Tab 菜单放不下多行）。
#    3) 行内灰字  ：PSReadLine 只在“缓冲区变化”时查询预测器，AI 答案晚到 1 秒通常来不及显示；
#                   当某行已缓存且再次被查询时会显示（按 → 接受）。所以主力是前两种。

#  触发规则（v1.4.0 起）：只有“像自然语言”的输入才会真的发请求；
#  缓存默认 10 分钟过期；同一行同时只有一个在途请求（连按 Tab/Alt+P 不会重复打 API）。

#  v1.5.0 新增：
#    · 一次给多个候选方案（Tab 菜单里选，默认 3 个，CandidateCount 可调）
#    · 安全刹车：高风险命令（递归删除 / 格式化磁盘 / git reset --hard 等）
#      · Tab 菜单里直接拦掉，不会让你手滑回车；
#      · Alt+P 需要连按两次确认才插入。
#    · 隐私日志：默认只记长度/语言/耗时，不记你输入的原话（LogInputs=true 才记）。
#    · 用量统计：Get-AIPredictorStatus -Stats（请求数 / 缓存命中率 / 延迟 / tokens / 估算成本）。
#
#  为什么用 C#：PowerShell 类也能实现 ICommandPredictor，但返回值 SuggestionPackage 是
#  结构体，PS 类 → CLR 接口的封送会丢内容（实测引擎只收到空包）。
# ========================================================================

using namespace System.Management.Automation.Subsystem
using namespace System.Management.Automation.Subsystem.Prediction

$script:Instance   = $null
$script:Config     = $null
$script:TypeName   = "AIPredictor.AIPredictorSource"
$script:TypeLoaded = $false
$script:Hotkey     = ""
$script:PendingDangerCommand = $null   # 等待第二次 Alt+P 确认的高风险命令
$script:PendingDangerAt = $null

# 版本号以 psd1 清单为准（单一来源）
$script:ModuleVersion = "0.0"
$manifestPath = Join-Path $PSScriptRoot "AIPredictor.psd1"
if (Test-Path -LiteralPath $manifestPath) {
    try { $script:ModuleVersion = [string](Import-PowerShellDataFile -LiteralPath $manifestPath).ModuleVersion } catch { }
}
$script:TabCompletionEnabled = $false
$script:OriginalTabExpansion2  = $null

# ------------------------------------------------------------------------
# 配置：config.json 里的值覆盖默认值
# ------------------------------------------------------------------------
function Get-AIPredictorConfig {
    if ($script:Config) { return $script:Config }

    $defaults = [ordered]@{
        Provider            = "Aliyun"
        Model               = "qwen3-max"
        ApiKey              = $(if ($env:LLM_API_KEY) { $env:LLM_API_KEY } elseif ($env:DEEPSEEK_API_KEY) { $env:DEEPSEEK_API_KEY } else { "" })
        Endpoint            = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        TimeoutSeconds      = 8
        MinInputLength      = 4
        DebounceMs          = 800
        MaxTokens           = 200
        Temperature         = 0.2
        MaxCacheEntries     = 200
        MaxSuggestionLength = 500
        Hotkey              = "Alt+P"
        EnableTabCompletion = $true
        CacheTtlSeconds     = 600
        AllowMultiLine      = $true
        LogInputs           = $false
        CandidateCount      = 3
        EnableMultiCandidate = $true
        PriceInPerM         = 0
        PriceOutPerM        = 0
        EnableLog           = $false
        LogPath             = (Join-Path $PSScriptRoot "ai_predictions.log")
        SystemPrompt        = ""
    }

    $configPath = Join-Path $PSScriptRoot "config.json"
    if (Test-Path -LiteralPath $configPath) {
        try {
            $user = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
            foreach ($key in $user.Keys) { $defaults[$key] = $user[$key] }
        }
        catch { Write-Warning "AIPredictor: config.json 解析失败，使用默认配置 —— $($_.Exception.Message)" }
    }
    else {
        Write-Warning "AIPredictor: 未找到 $configPath，使用默认配置（需要在其中填写 ApiKey）"
    }

    $script:Config = $defaults
    return $script:Config
}

# ------------------------------------------------------------------------
# 编译 / 加载 C# 预测器类型（结果缓存到 bin\，避免每次启动都编译）
# ------------------------------------------------------------------------
function Initialize-AIPredictorType {
    if ($script:TypeLoaded) { return }
    if ($script:TypeName -as [type]) { $script:TypeLoaded = $true; return }

    $sourcePath = Join-Path $PSScriptRoot "src\AIPredictorSource.cs"
    if (-not (Test-Path -LiteralPath $sourcePath)) { throw "找不到预测器源码：$sourcePath" }

    $source = Get-Content -LiteralPath $sourcePath -Raw -ErrorAction Stop

    # 缓存文件名带上源码哈希：不同版本互不覆盖，
    # 这样别的 PowerShell 会话正在用旧 DLL 时，新会话也能正常编译自己的版本（不会“文件被占用/拒绝访问”）。
    $hash8  = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.Substring(0, 8)
    $binDir = Join-Path $PSScriptRoot "bin"
    $dll    = Join-Path $binDir "AIPredictor.Predictor.$hash8.dll"

    if (Test-Path -LiteralPath $dll) {
        try {
            Add-Type -Path $dll -ErrorAction Stop
            $script:TypeLoaded = $true
            return
        }
        catch {
            # 与当前 PowerShell 不兼容：删掉重编
            try { Remove-Item -LiteralPath $dll -Force -ErrorAction Stop } catch { }
        }
    }

    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    try {
        Add-Type -TypeDefinition $source -OutputAssembly $dll -ErrorAction Stop
    }
    catch {
        # 写不了 DLL（目录只读等）：退化为仅内存编译，功能不受影响
        if (-not ($script:TypeName -as [type])) { Add-Type -TypeDefinition $source -ErrorAction Stop }
    }

    # -OutputAssembly 只写文件、不把类型载入会话，所以这里再显式加载一次
    if (-not ($script:TypeName -as [type])) { Add-Type -Path $dll -ErrorAction Stop }

    # 清理旧版本的编译产物（含早期不带哈希的文件名；正被别的会话占用就跳过）
    # 清理旧版本编译产物：-ErrorAction Ignore 既不出错、也不往 $Error 里塞记录（被别的会话占用就留着）
    Get-ChildItem -LiteralPath $binDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "AIPredictor.Predictor*.dll" -and $_.FullName -ne $dll } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Ignore }

    $script:TypeLoaded = $true
}

# ------------------------------------------------------------------------
# 用配置构造预测器实例
# ------------------------------------------------------------------------
function Initialize-AIPredictor {
    if ($script:Instance) { return $script:Instance }

    Initialize-AIPredictorType
    $config = Get-AIPredictorConfig

    $options = [AIPredictor.AIPredictorOptions]::new()
    foreach ($key in "ApiKey", "Model", "Endpoint", "LogPath", "SystemPrompt") {
        if ($config[$key]) { $options.$key = [string]$config[$key] }
    }
    foreach ($key in "TimeoutSeconds", "MinInputLength", "DebounceMs", "MaxTokens", "MaxCacheEntries", "MaxSuggestionLength", "CacheTtlSeconds", "CandidateCount") {
        if ($config[$key]) { $options.$key = [int]$config[$key] }
    }
    if ($config["Temperature"]) { $options.Temperature = [double]$config["Temperature"] }
    if ($config["PriceInPerM"])  { $options.PriceInPerM  = [double]$config["PriceInPerM"] }
    if ($config["PriceOutPerM"]) { $options.PriceOutPerM = [double]$config["PriceOutPerM"] }
    $options.EnableLog = [bool]$config["EnableLog"]
    $options.AllowMultiLine = [bool]$config["AllowMultiLine"]
    $options.LogInputs = [bool]$config["LogInputs"]
    $options.EnableMultiCandidate = [bool]$config["EnableMultiCandidate"]

    $script:Instance = [AIPredictor.AIPredictorSource]::new($options)
    return $script:Instance
}

# ------------------------------------------------------------------------
# 子系统注册状态 / 预测源 / 快捷键
# ------------------------------------------------------------------------
function Test-AIPredictorRegistered {
    if (-not $script:Instance) { return $false }
    try {
        $implementations = @([SubsystemManager]::GetSubsystemInfo([ICommandPredictor]).Implementations)
        return [bool]($implementations | Where-Object { $_ -and $_.Id -eq $script:Instance.Id })
    }
    catch { return $false }
}

function Set-AIPredictorPredictionSource {
    # 注意：不能用 Get-Module PSReadLine 判断 —— pwsh -File / 新会话里 PSReadLine 尚未 Import，
    # 但它的命令是可发现的（模块自动加载），用 Get-Command 才准。
    if (-not (Get-Command Set-PSReadLineOption -ErrorAction Ignore)) { return }

    # 输出被重定向（管道、CI、脚本）时 PSReadLine 开不了预测，直接跳过，免得刷一条无用错误
    try { if ([Console]::IsOutputRedirected) { return } } catch { }

    try {
        $current = (Get-PSReadLineOption).PredictionSource
        if ($current -ne "HistoryAndPlugin" -and $current -ne "Plugin") {
            Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction Stop
        }
    }
    catch { }
}

# Alt+P 的处理逻辑：同步问一次 AI，把建议写进命令行（不自动执行）
$script:KeyHandler = {
    param($key, $arg)

    $line = ""
    $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    if ([string]::IsNullOrWhiteSpace($line)) { return }

    $originalTitle = $null
    $timeoutMs = [int]($script:Config["TimeoutSeconds"] * 1000)
    if ($timeoutMs -lt 3000) { $timeoutMs = 3000 }

    try {
        $originalTitle = $Host.UI.RawUI.WindowTitle
        $Host.UI.RawUI.WindowTitle = "⏳ AIPredictor 正在向 AI 询问…"
    }
    catch { }

    try { $suggestion = $script:Instance.Query($line, $timeoutMs) }
    finally {
        if ($originalTitle) { try { $Host.UI.RawUI.WindowTitle = $originalTitle } catch { } }
    }

    if ($suggestion) {
        $dangerReason = [AIPredictor.AIPredictorSource]::GetDangerReason($suggestion)
        if ($dangerReason) {
            if ($script:Instance) { $script:Instance.NoteSafetyBlock() }
            $now = Get-Date
            $confirmed = ($script:PendingDangerCommand -eq $suggestion) -and
                         $script:PendingDangerAt -and
                         (($now - $script:PendingDangerAt).TotalSeconds -lt 30)
            if (-not $confirmed) {
                $script:PendingDangerCommand = $suggestion
                $script:PendingDangerAt = $now
                Write-Host ""
                Write-Host "⚠ 高风险命令（$dangerReason）：" -ForegroundColor Yellow
                Write-Host "   $suggestion" -ForegroundColor Yellow
                Write-Host "   再按一次 Alt+P 确认插入；30 秒内不确认自动失效" -ForegroundColor DarkGray
                return
            }
            $script:PendingDangerCommand = $null
            $script:PendingDangerAt = $null
            Write-Host ""
            Write-Host "⚠ 已确认插入高风险命令（$dangerReason），请检查无误后再回车" -ForegroundColor Yellow
        }
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, $line.Length, $suggestion, $null, $null)
    }
    else {
        Write-Host ""
        Write-Warning "没有取到 AI 建议：$($script:Instance.LastError)"
        Write-Host "  排查：Get-AIPredictorStatus    手动测试：Get-AIPredictorSuggestion -InputText 你的需求" -ForegroundColor DarkGray
    }
}

function Set-AIPredictorKeyHandler {
    param([string]$Chord)

    if (-not $Chord) { return }
    if (-not (Get-Command Set-PSReadLineKeyHandler -ErrorAction SilentlyContinue)) { return }

    $isConsole = $true
    try { $isConsole = -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected } catch { $isConsole = $false }
    if (-not $isConsole) { return }

    try {
        Remove-PSReadLineKeyHandler -Chord $Chord -ErrorAction SilentlyContinue
        Set-PSReadLineKeyHandler -Chord $Chord -BriefDescription "AIPredictor" -Description "向 AI 询问当前输入对应的 PowerShell 命令" -ScriptBlock $script:KeyHandler -ErrorAction Stop
        $script:Hotkey = $Chord
    }
    catch { Write-Warning "AIPredictor: 快捷键 $Chord 绑定失败 —— $($_.Exception.Message)" }
}

# ------------------------------------------------------------------------
# Tab 补全接管：输入像自然语言时，Tab 菜单第一项就是 AI 给出的整行命令
#
#   为什么需要它：PSReadLine 只在“缓冲区发生变化”时查询预测器，AI 的答案晚到 1 秒，
#   那时已经没有触发点，所以行内灰字经常根本不会出现。Tab 是用户主动触发，
#   可以同步等答案，稳定可用。（行内预测仍保留，命中缓存时会显示）
# ------------------------------------------------------------------------
$script:TabExpansionWrapper = {
    param($line, $cursorColumn)

    # 原生补全先算好；AI 出问题时也要保证 Tab 还能正常工作
    $base = $null
    try { if ($script:OriginalTabExpansion2) { $base = & $script:OriginalTabExpansion2 $line $cursorColumn } } catch { $base = $null }

    # 只接管“像自然语言”的输入（中/英整句），命令编辑完全不受影响；
    # 判断与 C# 预测器共用同一个方法，避免两边规则不一致
    if ([string]::IsNullOrWhiteSpace($line) -or
        -not [AIPredictor.AIPredictorSource]::IsNaturalLanguage($line)) {
        if ($null -eq $base) { $base = New-EmptyCompletion }
        return $base
    }

    $candidates = @()
    try {
        $timeoutMs = [int]($script:Config["TimeoutSeconds"] * 1000)
        if ($timeoutMs -lt 3000) { $timeoutMs = 3000 }
        $candidateCount = [int]$script:Config["CandidateCount"]
        if ($candidateCount -lt 1) { $candidateCount = 1 }
        $title = $null
        try { $title = $Host.UI.RawUI.WindowTitle; $Host.UI.RawUI.WindowTitle = "⏳ AIPredictor 正在向 AI 询问…" } catch { }
        try { $candidates = @($script:Instance.QueryCandidates($line, $timeoutMs, $candidateCount)) }
        finally { if ($title) { try { $Host.UI.RawUI.WindowTitle = $title } catch { } } }
    }
    catch { $candidates = @() }

    # 多行脚本在 Tab 菜单里放不下（换行会破坏菜单），交给 Alt+P 整段插入
    $singleLine = @($candidates | Where-Object { $_ -and $_.IndexOf([char]10) -lt 0 })
    if ($candidates.Count -gt 0 -and $singleLine.Count -eq 0) {
        Write-Host "   AIPredictor：AI 给出的是多行脚本，按 Alt+P 可整段插入" -ForegroundColor DarkGray
    }
    if ($singleLine.Count -eq 0) {
        if ($script:Instance -and $script:Instance.LastError) {
            Write-Warning "AIPredictor: $($script:Instance.LastError)"
            Write-Host "   已回退到普通补全；排查请运行 Test-AIPredictor" -ForegroundColor DarkGray
        }
        if ($null -eq $base) { $base = New-EmptyCompletion }
        return $base
    }

    # 安全刹车：高风险方案不放进 Tab 菜单（避免手滑回车）
    $safe = @()
    $blocked = 0
    $blockedReasons = @()
    foreach ($candidate in $singleLine) {
        $reason = [AIPredictor.AIPredictorSource]::GetDangerReason($candidate)
        if ($reason) {
            $blocked++
            if ($blockedReasons -notcontains $reason) { $blockedReasons += $reason }
        }
        else { $safe += $candidate }
    }
    if ($blocked -gt 0 -and $script:Instance) { $script:Instance.NoteSafetyBlock() }
    if ($blocked -gt 0) {
        Write-Host ("   ⚠ 已拦截 {0} 个高风险建议（{1}）；确实需要请按 Alt+P 确认插入" -f $blocked, ($blockedReasons -join "、")) -ForegroundColor Yellow
    }
    if ($safe.Count -eq 0) {
        if ($null -eq $base) { $base = New-EmptyCompletion }
        return $base
    }

    $matches = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
    $index = 0
    foreach ($candidate in $safe) {
        $index++
        $tip = if ($safe.Count -eq 1) {
            "AI 建议（$($script:Config["Model"])）：回车/Tab 采用，替换整行"
        }
        else {
            "方案 $index/$($safe.Count)（AI）：回车/Tab 采用，替换整行"
        }
        $matches.Add([System.Management.Automation.CompletionResult]::new(
            $candidate, $candidate, [System.Management.Automation.CompletionResultType]::Text, $tip))
    }
    return [System.Management.Automation.CommandCompletion]::new($matches, 0, 0, $line.Length)
}

function New-EmptyCompletion {
    $empty = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
    return [System.Management.Automation.CommandCompletion]::new($empty, -1, 0, 0)
}

function Enable-AIPredictorTabCompletion {
    [CmdletBinding()]
    param()

    if (-not (Get-Command TabExpansion2 -CommandType Function -ErrorAction Ignore)) { return $false }

    # 原始实现只捕获一次；重复导入时不要把我们自己的包装当成原始实现（会递归）
    if (-not $global:__AIPredictorOriginalTabExpansion) {
        $global:__AIPredictorOriginalTabExpansion = (Get-Command TabExpansion2 -CommandType Function -ErrorAction Ignore).ScriptBlock
    }
    $script:OriginalTabExpansion2 = $global:__AIPredictorOriginalTabExpansion

    try {
        Set-Item -Path function:global:TabExpansion2 -Value $script:TabExpansionWrapper -ErrorAction Stop
        return $true
    }
    catch {
        Write-Warning "AIPredictor: Tab 补全接管失败 —— $($_.Exception.Message)"
        return $false
    }
}

function Disable-AIPredictorTabCompletion {
    [CmdletBinding()]
    param()
    if ($global:__AIPredictorOriginalTabExpansion) {
        try { Set-Item -Path function:global:TabExpansion2 -Value $global:__AIPredictorOriginalTabExpansion -ErrorAction Stop } catch { }
    }
}

# ------------------------------------------------------------------------
# 对外命令
# ------------------------------------------------------------------------
function Register-AIPredictor {
    <#
    .SYNOPSIS
        注册 AI 预测器（子系统 + 预测源 + 快捷键）；模块导入时会自动调用一次。
    #>
    [CmdletBinding()]
    param([switch]$SkipHotkey)

    $instance = Initialize-AIPredictor
    $config = Get-AIPredictorConfig

    if (-not (Test-AIPredictorRegistered)) {
        [SubsystemManager]::RegisterSubsystem([SubsystemKind]::CommandPredictor, $instance)
    }

    Set-AIPredictorPredictionSource
    if (-not $SkipHotkey) { Set-AIPredictorKeyHandler -Chord $config["Hotkey"] }
    if ($config["EnableTabCompletion"]) { $script:TabCompletionEnabled = Enable-AIPredictorTabCompletion }

    return $instance
}

function Unregister-AIPredictor {
    <#
    .SYNOPSIS
        注销 AI 预测器（撤销子系统注册与快捷键绑定）。
    #>
    [CmdletBinding()]
    param()

    if ($script:Instance -and (Test-AIPredictorRegistered)) {
        try { [SubsystemManager]::UnregisterSubsystem([SubsystemKind]::CommandPredictor, $script:Instance.Id) } catch { }
    }
    if ($script:Hotkey) {
        try { Remove-PSReadLineKeyHandler -Chord $script:Hotkey -ErrorAction SilentlyContinue } catch { }
        $script:Hotkey = ""
    }
    if ($script:TabCompletionEnabled) {
        Disable-AIPredictorTabCompletion
        $script:TabCompletionEnabled = $false
    }
}

function Get-AIPredictorSuggestion {
    <#
    .SYNOPSIS
        同步问一次 AI，返回它给出的命令（用于测试或写进自己的脚本）。
    .EXAMPLE
        Get-AIPredictorSuggestion -InputText "把当前目录里超过 100MB 的文件列出来"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)][string]$InputText,
        [int]$TimeoutMs = 0
    )

    $instance = Initialize-AIPredictor
    if ($TimeoutMs -le 0) { $TimeoutMs = [int]((Get-AIPredictorConfig)["TimeoutSeconds"] * 1000) }
    return $instance.Query($InputText, $TimeoutMs)
}

function Get-AIPredictorStatus {
    <#
    .SYNOPSIS
        查看 AI 预测器的配置与注册状态；-Stats 额外显示用量统计。
    .EXAMPLE
        Get-AIPredictorStatus -Stats
    #>
    [CmdletBinding()]
    param([switch]$Stats)

    $config = Get-AIPredictorConfig
    $instance = $script:Instance

    $maskedKey = "(未配置)"
    if ($config["ApiKey"]) {
        $key = [string]$config["ApiKey"]
        $maskedKey = $(if ($key.Length -gt 10) { $key.Substring(0, 6) + "..." + $key.Substring($key.Length - 4) } else { "已配置" })
    }

    $predictionSource = "n/a"
    try { $predictionSource = (Get-PSReadLineOption).PredictionSource } catch { }

    # 注意：变量名不能叫 $stats —— 会和 [switch]$Stats 参数冲突（PowerShell 变量名大小写不敏感）
    $statistics = $null
    if ($instance) { $statistics = $instance.Stats }

    if ($Stats -and $statistics) {
        Write-Host ""
        Write-Host "=== AIPredictor 用量统计（本次会话）===" -ForegroundColor Cyan
        Write-Host ("  请求次数    : {0}（失败 {1}）" -f $statistics.Requests, $statistics.Failures)
        Write-Host ("  缓存        : 命中率 {0}%（命中 {1} / 未命中 {2}，当前缓存 {3} 条）" -f $statistics.HitRate, $statistics.CacheHits, $statistics.CacheMisses, $instance.CacheCount)
        Write-Host ("  延迟        : 平均 {0} ms（最近 {1} ms）" -f $statistics.AvgLatencyMs, [int]$statistics.LastLatencyMs)
        Write-Host ("  行内建议    : 显示 {0} 次" -f $statistics.InlineHits)
        Write-Host ("  安全刹车    : {0} 次" -f $statistics.SafetyBlocks)
        Write-Host ("  Tokens      : 输入 {0} / 输出 {1}" -f $statistics.PromptTokens, $statistics.CompletionTokens)
        $priceIn = [double]$config["PriceInPerM"]
        $priceOut = [double]$config["PriceOutPerM"]
        if ($priceIn -gt 0 -or $priceOut -gt 0) {
            $cost = ($statistics.PromptTokens / 1000000.0) * $priceIn + ($statistics.CompletionTokens / 1000000.0) * $priceOut
            Write-Host ("  估算成本    : {0:N4}（按每百万 token 输入 {1} / 输出 {2}）" -f $cost, $priceIn, $priceOut)
        }
        else {
            Write-Host "  估算成本    : 未配置单价（config.json 里设 PriceInPerM / PriceOutPerM 即可显示）" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    [pscustomobject]@{
        Version          = $script:ModuleVersion
        Model            = $config["Model"]
        Endpoint         = $config["Endpoint"]
        ApiKey           = $maskedKey
        TypeLoaded       = [bool]($script:TypeName -as [type])
        Registered       = Test-AIPredictorRegistered
        PredictionSource = $predictionSource
        Hotkey           = $(if ($script:Hotkey) { $script:Hotkey } else { "(未绑定)" })
        CacheCount       = $(if ($instance) { $instance.CacheCount } else { 0 })
        CacheTtlSeconds  = $config["CacheTtlSeconds"]
        AllowMultiLine   = [bool]$config["AllowMultiLine"]
        LastError        = $(if ($instance) { $instance.LastError } else { "" })
        LogPath          = $config["LogPath"]
        Stats            = $statistics
    }
}

function Test-AIPredictor {
    <#
    .SYNOPSIS
        自检：把“为什么没反应”直接查出来（注册状态 / 预测源 / 快捷键 / 真实 API 请求 / 日志尾部）。
    .EXAMPLE
        Test-AIPredictor
    #>
    [CmdletBinding()]
    param(
        [string]$InputText = "列出当前目录下最大的 5 个文件",
        [int]$LogTail = 12
    )

    function Write-Item([string]$Name, [string]$Value, [string]$Color = "Gray") {
        Write-Host ("  {0,-12}: " -f $Name) -NoNewline
        Write-Host $Value -ForegroundColor $Color
    }

    $config = Get-AIPredictorConfig
    Write-Host ""
    Write-Host "=== AIPredictor 自检 ===" -ForegroundColor Cyan

    $key = [string]$config["ApiKey"]
    $masked = if ($key) { $key.Substring(0, [Math]::Min(6, $key.Length)) + "..." + $key.Substring([Math]::Max(0, $key.Length - 4)) } else { "(空！)" }
    Write-Item "模型" $config["Model"]
    Write-Item "接口" $config["Endpoint"]
    Write-Item "API Key" $masked $(if ($key) { "Gray" } else { "Red" })
    Write-Item "日志" $(if ($config["EnableLog"]) { $config["LogPath"] } else { "未开启（config.json 里 EnableLog=true 可开启）" })

    try {
        $null = Initialize-AIPredictor
        Write-Item "C# 类型" "已加载" "Green"
    }
    catch {
        Write-Item "C# 类型" "加载失败：$($_.Exception.Message)" "Red"
        return
    }

    $registered = Test-AIPredictorRegistered
    Write-Item "子系统注册" $(if ($registered) { "已注册" } else { "未注册（导入模块时应自动注册）" }) $(if ($registered) { "Green" } else { "Red" })

    $source = "取不到"
    try { $source = (Get-PSReadLineOption).PredictionSource } catch { }
    Write-Item "预测源" "$source" $(if ($source -eq "Plugin" -or $source -eq "HistoryAndPlugin") { "Green" } else { "Yellow" })
    Write-Item "快捷键" $(if ($script:Hotkey) { $script:Hotkey } else { "未绑定（非交互式会话属正常）" }) $(if ($script:Hotkey) { "Green" } else { "Yellow" })
    Write-Item "Tab 接管" $(if ($script:TabCompletionEnabled) { "已接管（自然语言整句按 Tab 出 AI 建议）" } else { "未接管" }) $(if ($script:TabCompletionEnabled) { "Green" } else { "Yellow" })
    Write-Item "多候选" $(if ($config["EnableMultiCandidate"]) { "开启（每次 $($config["CandidateCount"]) 个方案，高风险自动拦截）" } else { "关闭" }) "Gray"
    Write-Item "隐私日志" $(if ($config["LogInputs"]) { "会记录输入原文" } else { "只记长度/语言/耗时（不记原文）" }) "Gray"

    Write-Host "  实测一次 API 请求..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $suggestion = $script:Instance.Query($InputText, [int]($config["TimeoutSeconds"] * 1000))
    $sw.Stop()
    if ($suggestion) {
        Write-Item "API 请求" "成功（$($sw.ElapsedMilliseconds) ms）" "Green"
        Write-Host "     输入: $InputText" -ForegroundColor DarkGray
        Write-Host "     建议: $suggestion" -ForegroundColor Green
    }
    else {
        Write-Item "API 请求" "失败（$($sw.ElapsedMilliseconds) ms）" "Red"
        Write-Item "错误信息" $script:Instance.LastError "Red"
        Write-Host "     排查：代理是否可用（HTTP_PROXY=$env:HTTP_PROXY）、Key 是否有效、Endpoint 是否可达" -ForegroundColor Yellow
    }

    if ($config["EnableLog"] -and (Test-Path -LiteralPath $config["LogPath"])) {
        Write-Host "  日志尾部（$($config["LogPath"])）:" -ForegroundColor DarkGray
        Get-Content -LiteralPath $config["LogPath"] -Tail $LogTail -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
    }
    Write-Host ""
}

Export-ModuleMember -Function Register-AIPredictor, Unregister-AIPredictor, Get-AIPredictorSuggestion, Get-AIPredictorStatus, Test-AIPredictor

# ------------------------------------------------------------------------
# 导入即自动注册（不想自动注册可设 $env:AIPREDICTOR_SKIP_AUTOREGISTER = "1"）
# ------------------------------------------------------------------------
if ($env:AIPREDICTOR_SKIP_AUTOREGISTER -ne "1") {
    try { Register-AIPredictor | Out-Null }
    catch { Write-Warning "AIPredictor 自动注册失败：$($_.Exception.Message)" }
}
