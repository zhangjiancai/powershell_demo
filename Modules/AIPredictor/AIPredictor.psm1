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
#    1) 按 Tab    ：输入中文后按 Tab，菜单第一项就是 AI 给出的整行命令，回车/Tab 采用（推荐）
#    2) Alt+P     ：立即问 AI 并把建议写进命令行（默认 Alt+P，可在 config.json 改）
#    3) 行内灰字  ：PSReadLine 只在“缓冲区变化”时查询预测器，AI 答案晚到 1 秒通常来不及显示；
#                   当某行已缓存且再次被查询时会显示（按 → 接受）。所以主力是前两种。
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
    foreach ($key in "TimeoutSeconds", "MinInputLength", "DebounceMs", "MaxTokens", "MaxCacheEntries", "MaxSuggestionLength") {
        if ($config[$key]) { $options.$key = [int]$config[$key] }
    }
    if ($config["Temperature"]) { $options.Temperature = [double]$config["Temperature"] }
    $options.EnableLog = [bool]$config["EnableLog"]

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
# Tab 补全接管：输入含中文时，Tab 菜单第一项就是 AI 给出的整行命令
#
#   为什么需要它：PSReadLine 只在“缓冲区发生变化”时查询预测器，AI 的答案晚到 1 秒，
#   那时已经没有触发点，所以行内灰字经常根本不会出现。Tab 是用户主动触发，
#   可以同步等答案，稳定可用。（行内预测仍保留，命中缓存时会显示）
# ------------------------------------------------------------------------
$script:CjkPattern = "[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uac00-\ud7af]"

$script:TabExpansionWrapper = {
    param($line, $cursorColumn)

    # 原生补全先算好；AI 出问题时也要保证 Tab 还能正常工作
    $base = $null
    try { if ($script:OriginalTabExpansion2) { $base = & $script:OriginalTabExpansion2 $line $cursorColumn } } catch { $base = $null }

    # 只接管“像自然语言”的输入（含中文/日文/韩文），普通命令输入完全不受影响
    if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch $script:CjkPattern) {
        if ($null -eq $base) { $base = New-EmptyCompletion }
        return $base
    }

    $suggestion = $null
    try {
        $timeoutMs = [int]($script:Config["TimeoutSeconds"] * 1000)
        if ($timeoutMs -lt 3000) { $timeoutMs = 3000 }
        $title = $null
        try { $title = $Host.UI.RawUI.WindowTitle; $Host.UI.RawUI.WindowTitle = "⏳ AIPredictor 正在向 AI 询问…" } catch { }
        try { $suggestion = $script:Instance.Query($line, $timeoutMs) }
        finally { if ($title) { try { $Host.UI.RawUI.WindowTitle = $title } catch { } } }
    }
    catch { }

    if (-not $suggestion) {
        if ($script:Instance -and $script:Instance.LastError) {
            Write-Warning "AIPredictor: $($script:Instance.LastError)"
            Write-Host "   已回退到普通补全；排查请运行 Test-AIPredictor" -ForegroundColor DarkGray
        }
        if ($null -eq $base) { $base = New-EmptyCompletion }
        return $base
    }

    $item = [System.Management.Automation.CompletionResult]::new(
        $suggestion,
        $suggestion,
        [System.Management.Automation.CompletionResultType]::Text,
        "AI 建议（$($script:Config["Model"])）：回车/Tab 采用，替换整行"
    )
    $matches = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
    $matches.Add($item)
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
        查看 AI 预测器的配置与注册状态；排查问题先看它。
    #>
    [CmdletBinding()]
    param()

    $config = Get-AIPredictorConfig
    $instance = $script:Instance

    $maskedKey = "(未配置)"
    if ($config["ApiKey"]) {
        $key = [string]$config["ApiKey"]
        $maskedKey = $(if ($key.Length -gt 10) { $key.Substring(0, 6) + "..." + $key.Substring($key.Length - 4) } else { "已配置" })
    }

    $predictionSource = "n/a"
    try { $predictionSource = (Get-PSReadLineOption).PredictionSource } catch { }

    [pscustomobject]@{
        Model            = $config["Model"]
        Endpoint         = $config["Endpoint"]
        ApiKey           = $maskedKey
        TypeLoaded       = [bool]($script:TypeName -as [type])
        Registered       = Test-AIPredictorRegistered
        PredictionSource = $predictionSource
        Hotkey           = $(if ($script:Hotkey) { $script:Hotkey } else { "(未绑定)" })
        CacheCount       = $(if ($instance) { $instance.CacheCount } else { 0 })
        LastError        = $(if ($instance) { $instance.LastError } else { "" })
        LogPath          = $config["LogPath"]
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
    Write-Item "Tab 接管" $(if ($script:TabCompletionEnabled) { "已接管（含中文时 Tab 出 AI 建议）" } else { "未接管" }) $(if ($script:TabCompletionEnabled) { "Green" } else { "Yellow" })

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
