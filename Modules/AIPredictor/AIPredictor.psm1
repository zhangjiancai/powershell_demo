#Requires -Version 7.2
# ========================================================================
#  AIPredictor.psm1 —— AI 命令预测（PowerShell 引擎子系统 ICommandPredictor）
#
#  原理：
#    PowerShell 7.2+ 的引擎有“命令预测器”子系统；PSReadLine 打开 Plugin 预测源后
#    会调用注册进来的预测器。本模块把 C# 写的 AIPredictorSource（src\AIPredictorSource.cs）
#    编译并注册进去，于是你输入自然语言时，行内就会出现 AI 给出的命令建议。
#
#  两种用法：
#    1) 边打边猜：输入中文/自然语言，停一下再按任意键，行内灰字即为建议（按 → 接受）
#    2) 快捷键  ：Alt+P 立即问 AI 并把建议写进命令行（默认 Alt+P，可在 config.json 改）
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

# ------------------------------------------------------------------------
# 配置：config.json 里的值覆盖默认值
# ------------------------------------------------------------------------
function Get-AIPredictorConfig {
    if ($script:Config) { return $script:Config }

    $defaults = [ordered]@{
        Provider            = "Aliyun"
        Model               = "qwen3-max"
        ApiKey              = $env:LLM_API_KEY
        Endpoint            = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        TimeoutSeconds      = 8
        MinInputLength      = 4
        DebounceMs          = 800
        MaxTokens           = 200
        Temperature         = 0.2
        MaxCacheEntries     = 200
        MaxSuggestionLength = 500
        Hotkey              = "Alt+P"
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
    $hash   = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    $binDir = Join-Path $PSScriptRoot "bin"
    $dll    = Join-Path $binDir "AIPredictor.Predictor.dll"
    $stamp  = "$dll.sha256"

    # 命中缓存：源码没变就直接加载 DLL（几十毫秒，比现场编译快得多）
    if ((Test-Path -LiteralPath $dll) -and (Test-Path -LiteralPath $stamp) -and
        ((Get-Content -LiteralPath $stamp -Raw).Trim() -eq $hash)) {
        try {
            Add-Type -Path $dll -ErrorAction Stop
            $script:TypeLoaded = $true
            return
        }
        catch {
            # DLL 与当前 PowerShell 不兼容等情况：落到下面重新编译
        }
    }

    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    try {
        Add-Type -TypeDefinition $source -OutputAssembly $dll -ErrorAction Stop
        Set-Content -LiteralPath $stamp -Value $hash -Encoding utf8
    }
    catch {
        # 目录只读或写 DLL 失败：退化为仅内存编译
        Add-Type -TypeDefinition $source -ErrorAction Stop
    }

    if (-not ($script:TypeName -as [type])) { Add-Type -Path $dll -ErrorAction Stop }
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
    if (-not (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue)) { return }
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

Export-ModuleMember -Function Register-AIPredictor, Unregister-AIPredictor, Get-AIPredictorSuggestion, Get-AIPredictorStatus

# ------------------------------------------------------------------------
# 导入即自动注册（不想自动注册可设 $env:AIPREDICTOR_SKIP_AUTOREGISTER = "1"）
# ------------------------------------------------------------------------
if ($env:AIPREDICTOR_SKIP_AUTOREGISTER -ne "1") {
    try { Register-AIPredictor | Out-Null }
    catch { Write-Warning "AIPredictor 自动注册失败：$($_.Exception.Message)" }
}
