<#
.SYNOPSIS
    PowerShell 7 个人配置文件（稳定版 v1.2.0）

.DESCRIPTION
    设计原则
      1. 绝不 exit —— 任何一项配置失败都不会关闭你的终端窗口
      2. 分块 try/catch —— oh-my-posh、代理、模块各自独立，互不影响
      3. 只在交互式终端做交互的事 —— 管道 / 重定向 / CI 下自动跳过 PSReadLine、WinGet 等功能
      4. 路径集中在配置区，并且都能用环境变量覆盖，不必改本文件

    可用环境变量
      POSH_PROFILE_QUIET=1               启动时只显示警告，不打印汇总
      POSH_PROFILE_FORCE_INTERACTIVE=1   强制按交互式终端加载（排错用）
      OHMYPOSH_EXE=<exe 路径>            覆盖 oh-my-posh 可执行文件位置
      OHMYPOSH_THEMES=<目录>             覆盖主题目录
      OHMYPOSH_THEME=<json 路径>         固定主题（不设置则每次随机）

.NOTES
    文件：$PROFILE
    仓库：D:\<用户名>\Documents\PowerShell（git 管理，稳定版对应 tag v1.2.0）
#>

& {
    $ErrorActionPreference = 'Continue'   # 单项出错只提示，不中断整个配置

    # ============================================================
    # 配置区
    # ============================================================
    $ProfileDir  = Split-Path -Parent $PROFILE
    $Quiet       = $env:POSH_PROFILE_QUIET -eq '1'

    $OhMyPoshExe = if ($env:OHMYPOSH_EXE)    { $env:OHMYPOSH_EXE }    else { 'D:\APP_LOW\oh-my-posh\bin\oh-my-posh.exe' }
    $ThemeDir    = if ($env:OHMYPOSH_THEMES) { $env:OHMYPOSH_THEMES } else { 'D:\APP_LOW\oh-my-posh\themes' }
    $PinnedTheme = $env:OHMYPOSH_THEME

    $HistoryPath       = Join-Path $ProfileDir 'PSReadLine\ConsoleHost_history.txt'
    $AiPredictorModule = Join-Path $ProfileDir 'Modules\AIPredictor\AIPredictor.psm1'

    # 是否真正的交互式控制台（Windows Terminal / VS Code 终端都算；管道、重定向、CI 不算）
    $IsConsole = $false
    try {
        $IsConsole = ($env:POSH_PROFILE_FORCE_INTERACTIVE -eq '1') -or (
            $Host.Name -eq 'ConsoleHost' -and
            -not [Console]::IsOutputRedirected -and
            -not [Console]::IsInputRedirected
        )
    }
    catch { $IsConsole = $false }

    # 启动汇总：先收集，最后一次性打印
    $Summary = [System.Collections.Generic.List[object]]::new()
    function Add-Summary {
        param([string]$Text, [string]$Color = 'DarkGray')
        $Summary.Add([pscustomobject]@{ Text = $Text; Color = $Color })
    }

    # ============================================================
    # 1. oh-my-posh：定位程序 → 选主题 → 初始化提示符
    # ============================================================
    try {
        if (-not (Test-Path -LiteralPath $OhMyPoshExe -PathType Leaf)) {
            $onPath = Get-Command oh-my-posh -ErrorAction SilentlyContinue
            if ($onPath) { $OhMyPoshExe = $onPath.Source }
        }

        if (Test-Path -LiteralPath $OhMyPoshExe -PathType Leaf) {
            $ompVersion = (Get-Item -LiteralPath $OhMyPoshExe).VersionInfo.FileVersion

            $theme = $null
            if ($PinnedTheme -and (Test-Path -LiteralPath $PinnedTheme -PathType Leaf)) {
                $theme = Get-Item -LiteralPath $PinnedTheme
            }
            elseif (Test-Path -LiteralPath $ThemeDir) {
                $themes = @(Get-ChildItem -LiteralPath $ThemeDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
                if ($themes.Count -gt 0) { $theme = $themes | Get-Random }
            }

            if ($theme) {
                $initScript = & $OhMyPoshExe --init --shell pwsh --config $theme.FullName 2>$null | Out-String
                if ($initScript.Trim()) {
                    $initScript | Invoke-Expression
                    Add-Summary "oh-my-posh $ompVersion · 主题 $($theme.Name)"
                }
                else {
                    Add-Summary 'oh-my-posh 初始化没有输出，已跳过（提示符保持默认）' 'Yellow'
                }
            }
            else {
                Add-Summary "oh-my-posh $ompVersion · 没找到主题文件，提示符保持默认" 'Yellow'
            }
        }
        else {
            Add-Summary "oh-my-posh 未找到：$OhMyPoshExe（已跳过）" 'Yellow'
        }
    }
    catch {
        Add-Summary "oh-my-posh 初始化失败：$($_.Exception.Message)（已跳过）" 'Yellow'
    }

    # ============================================================
    # 2. 系统代理 → 环境变量
    # ============================================================
    try {
        $ie = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop

        if ($ie.ProxyEnable -eq 1 -and $ie.ProxyServer) {
            $rawProxy = [string]$ie.ProxyServer
            $proxyAddress = $null

            # 注册表可能是 "127.0.0.1:7897"，也可能是 "http=127.0.0.1:7897;https=127.0.0.1:7897"
            foreach ($piece in ($rawProxy -split ';')) {
                $part = $piece.Trim()
                if ($part -match '^(?:[a-zA-Z]+=)?(?<addr>[^=\s]+:\d+)$') {
                    $proxyAddress = $Matches['addr']
                    break
                }
            }

            if ($proxyAddress) {
                $env:HTTP_PROXY  = "http://$proxyAddress"
                $env:HTTPS_PROXY = "http://$proxyAddress"
                Add-Summary "代理 $proxyAddress"
            }
            else {
                Add-Summary "代理地址无法解析：$rawProxy（已跳过）" 'Yellow'
            }

            if ($ie.ProxyUser) {
                Write-Warning "系统代理需要认证（用户名：$($ie.ProxyUser)），请自行配置凭据。"
            }
        }
        else {
            Add-Summary '代理 系统未启用（已跳过）'
        }
    }
    catch {
        Add-Summary "代理读取失败：$($_.Exception.Message)（已跳过）" 'Yellow'
    }

    # ============================================================
    # 3. PSReadLine：命令历史文件位置
    # ============================================================
    $psrlReady = $false

    if ($IsConsole) {
        try {
            if (-not (Get-Module PSReadLine)) { Import-Module PSReadLine -ErrorAction Stop }

            $historyDir = Split-Path -Parent $HistoryPath
            if (-not (Test-Path -LiteralPath $historyDir)) {
                New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
            }

            Set-PSReadLineOption -HistorySavePath $HistoryPath -ErrorAction Stop
            $psrlReady = $true
            Add-Summary "命令历史 $HistoryPath"
        }
        catch {
            Add-Summary "命令历史配置失败：$($_.Exception.Message)" 'Yellow'
        }
    }
    else {
        Add-Summary '命令历史 非交互式会话，已跳过 PSReadLine 配置'
    }

    # ============================================================
    # 4. 模块加载
    # ============================================================
    $predictorLoaded = $false
    $aiLoaded        = $false

    # Microsoft.WinGet.CommandNotFound 只在真正的控制台里加载：
    # 它在非交互进程退出时会抛未处理异常（PowerToys 模块的已知问题）。
    $modulesToLoad = @('Az.Tools.Predictor')
    if ($IsConsole) { $modulesToLoad += 'Microsoft.WinGet.CommandNotFound' }

    foreach ($moduleName in $modulesToLoad) {
        try {
            $available = @(Get-Module -Name $moduleName -ListAvailable -ErrorAction SilentlyContinue)
            if ($available.Count -eq 0) {
                Write-Warning "模块未安装：$moduleName"
                continue
            }

            $latest = $available | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
            Import-Module -Name $moduleName -RequiredVersion $latest.Version -ErrorAction Stop

            if ($moduleName -eq 'Az.Tools.Predictor') { $predictorLoaded = $true }
            Add-Summary "模块 $moduleName v$($latest.Version)"
        }
        catch {
            Write-Warning "模块加载失败：$moduleName —— $($_.Exception.Message)"
        }
    }

    # 本地 AI 预测插件（可选：文件不存在或加载失败都只是跳过）
    # 模块导入时会自行完成：编译/加载 C# 预测器 → 注册到引擎 → 绑定 Alt+P 快捷键
    if ($IsConsole -and (Test-Path -LiteralPath $AiPredictorModule -PathType Leaf)) {
        try {
            Import-Module -Name $AiPredictorModule -Force -ErrorAction Stop
            $aiLoaded = $true
            Add-Summary '模块 AIPredictor（中文输入按 Tab 出 AI 建议；Alt+P 直接问）'
        }
        catch {
            Write-Warning "AIPredictor 加载失败：$($_.Exception.Message)"
        }
    }

    # ============================================================
    # 5. PSReadLine 预测与快捷键（仅交互式终端）
    # ============================================================
    if ($psrlReady) {
        try {
            $predictionSource = if ($predictorLoaded -or $aiLoaded) { 'HistoryAndPlugin' } else { 'History' }
            Set-PSReadLineOption -PredictionSource $predictionSource -ErrorAction Stop
            Set-PSReadLineOption -MaximumHistoryCount 100000 -ErrorAction Stop
            Set-PSReadLineOption -PredictionViewStyle InlineView -ErrorAction Stop
            Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete -ErrorAction Stop

            if ($predictorLoaded -or $aiLoaded) {
                $pluginNames = @()
                if ($predictorLoaded) { $pluginNames += 'Az.Tools.Predictor' }
                if ($aiLoaded)        { $pluginNames += 'AIPredictor' }
                Add-Summary "智能预测 $predictionSource（$($pluginNames -join ' + ')）"
            }
            else {
                Add-Summary "智能预测 $predictionSource（未检测到预测插件）" 'Yellow'
            }
        }
        catch {
            # 预测功能不可用时退回历史记录预测，绝不影响终端正常使用
            try { Set-PSReadLineOption -PredictionSource History -ErrorAction SilentlyContinue } catch { }
            Add-Summary "智能预测不可用：$($_.Exception.Message)" 'Yellow'
        }
    }

    # ============================================================
    # 6. 启动汇总
    # ============================================================
    if (-not $Quiet) {
        Write-Host ''
        Write-Host '=== PowerShell 配置已加载（稳定版 v1.2.0）===' -ForegroundColor Cyan
        foreach ($item in $Summary) {
            Write-Host "  $($item.Text)" -ForegroundColor $item.Color
        }
        Write-Host ''
    }
}
