<#
.SYNOPSIS
PowerShell 配置文件增强版
- 更清晰的错误标识
- 增强可读性
- 模块化结构
#>

#region OhMyPosh 初始化
try {
    # 使用驼峰式变量命名
    $OhMyPoshPath = "D:\APP_LOW\oh-my-posh\bin\oh-my-posh.exe"

    if (-not (Test-Path -Path $OhMyPoshPath -PathType Leaf)) {
        # 使用红色错误标识 + 问题路径标注
        Write-Error "[!] OhMyPosh 未找到！问题路径：" 
        Write-Host "    $OhMyPoshPath" -ForegroundColor Red
        exit 1
    }

    Write-Host "`n=== OhMyPosh 配置 ===" -ForegroundColor Cyan
    Write-Host "已加载 OhMyPosh ($((Get-Item $OhMyPoshPath).VersionInfo.FileVersion))"
}
catch {
    Write-Error "[初始化失败] OhMyPosh 配置异常：$_"
    exit 2
}
#endregion

#region 代理配置
try {
    Write-Host "`n=== 网络代理配置 ===" -ForegroundColor Cyan
    
    $proxySettings = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop

    if ($proxySettings.ProxyEnable -eq 1 -and $proxySettings.ProxyServer) {
        $proxyAddress = $proxySettings.ProxyServer
        
        # 代理地址格式验证
        if ($proxyAddress -notmatch '^[\w\.-]+:\d+$') {
            Write-Error "[!] 代理地址格式错误："
            Write-Host "    当前值: '$proxyAddress'" -ForegroundColor Red
            Write-Host "    预期格式: 'host:port'" -ForegroundColor Yellow
            exit 3
        }

        # 设置环境变量（黄色高亮关键操作）
        Write-Host "系统代理已启用 → " -NoNewline
        Write-Host $proxyAddress -ForegroundColor Yellow
        
        $env:HTTP_PROXY = "http://$proxyAddress"
        $env:HTTPS_PROXY = "http://$proxyAddress"  # 保持协议统一

        # 凭据提示（如果检测到）
        if ($proxySettings.ProxyUser) {
            Write-Warning "检测到需要代理认证（用户名: $($proxySettings.ProxyUser)）"
            Write-Warning "提示：请手动配置认证信息！"
        }
    }
    else {
        Write-Host "系统代理未启用" -ForegroundColor DarkGray
    }
}
catch {
    Write-Error "[代理配置失败] $_"
    exit 4
}
#endregion

#region 主题配置
try {
    Write-Host "`n=== 终端主题配置 ===" -ForegroundColor Cyan
    
    $themeDir = "D:\APP_LOW\oh-my-posh\themes"
    $themeFiles = Get-ChildItem -Path $themeDir -Filter *.json -ErrorAction Stop

    if ($themeFiles.Count -eq 0) {
        Write-Error "[!] 未找到主题文件："
        Write-Host "    目录: $themeDir" -ForegroundColor Red
        exit 5
    }

    $randomTheme = $themeFiles | Get-Random
    Write-Host "今日随机主题 → " -NoNewline
    Write-Host $randomTheme.Name -ForegroundColor Magenta

    # 初始化主题（绿色高亮关键操作）
    & $OhMyPoshPath --init --shell pwsh --config $randomTheme.FullName | Invoke-Expression
    Write-Host "主题已应用 √" -ForegroundColor Green
}
catch {
    Write-Error "[主题配置失败] $_"
    exit 6
}
#endregion

#region 历史记录配置
try {
    Write-Host "`n=== 命令历史配置 ===" -ForegroundColor Cyan
    
    $historyPath = "D:\<用户名>\Documents\PowerShell\PSReadLine\ConsoleHost_history.txt"
    $historyDir = Split-Path $historyPath -Parent

    if (-not (Test-Path -Path $historyDir)) {
        Write-Host "创建历史记录目录 → " -NoNewline
        Write-Host $historyDir -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
    }

    Set-PSReadLineOption -HistorySavePath $historyPath
    Write-Host "历史记录文件 → " -NoNewline
    Write-Host $historyPath -ForegroundColor Cyan
}
catch {
    Write-Error "[历史记录配置失败] $_"
    exit 7
}
#endregion

#region 模块加载
try {
    Write-Host "`n=== 模块加载 ===" -ForegroundColor Cyan

    # 标准 PowerShellGallery 模块（可直接 Import-Module）
    $galleryModules = @(
        "Az.Tools.Predictor",
        "Microsoft.WinGet.CommandNotFound"
    )

    foreach ($module in $galleryModules) {
        $availableModules = Get-Module -Name $module -ListAvailable
        
        if (-not $availableModules) {
            Write-Warning "[!] 模块未安装: $module"
            Write-Host "    问题模块: $module" -ForegroundColor Red
            continue
        }

        $latestModule = $availableModules | 
                       Sort-Object { [version]$_.Version } -Descending | 
                       Select-Object -First 1
        
        if (-not (Test-Path $latestModule.ModuleBase)) {
            Write-Error "[!] 模块路径异常："
            Write-Host "    模块名称: $module" -ForegroundColor Red
            Write-Host "    异常路径: $($latestModule.ModuleBase)" -ForegroundColor Red
            continue
        }

        Import-Module $module -ErrorAction Stop
        Write-Host "已加载模块 → " -NoNewline
        Write-Host $module -ForegroundColor Green -NoNewline
        Write-Host " (v$($latestModule.Version))" -ForegroundColor DarkYellow
        Write-Host "    安装路径: $($latestModule.ModuleBase)" -ForegroundColor DarkGray
    }

    # --- 处理 AIPredictor 插件 ---
    $aiPredictorPath = Join-Path (Split-Path $PROFILE -Parent) "Modules\AIPredictor\AIPredictor.psm1"
    if (Test-Path $aiPredictorPath) {
        try {
            # 1. 确保使用最新 PSReadLine
            Remove-Module PSReadLine -ErrorAction SilentlyContinue
            $latestPSRL = Get-Module PSReadLine -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
            if ($latestPSRL) {
                Import-Module PSReadLine -RequiredVersion $latestPSRL.Version -Force
                Write-Host "已加载模块 → PSReadLine v$($latestPSRL.Version)" -ForegroundColor DarkGray
            } else {
                Write-Warning "[!] 未找到 PSReadLine 模块"
                # 不 return，继续执行其他逻辑
            }

            # 2. 加载 AIPredictor 模块
            Import-Module $aiPredictorPath -Force -ErrorAction Stop
            Write-Host "已加载本地插件 → " -NoNewline
            Write-Host "AIPredictor" -ForegroundColor Green -NoNewline
            Write-Host " (自定义 AI 预测)" -ForegroundColor DarkYellow
            Write-Host "    路径: $aiPredictorPath" -ForegroundColor DarkGray

            # 3. 检查 Register-AIPredictor 函数是否存在
            if (-not (Get-Command Register-AIPredictor -ErrorAction SilentlyContinue)) {
                Write-Warning "[!] AIPredictor 模块缺少 Register-AIPredictor 函数"
                # 不 return，继续
            } else {
                # ========== 正确包装 Oh My Posh 的 prompt ==========
                try {
                    # 获取原始 prompt 函数体（ScriptBlock）
                    $originalPrompt = Get-Command prompt -ErrorAction Stop | Select-Object -ExpandProperty ScriptBlock

                    # 定义新的包装 prompt 函数
                    Set-Content function:\prompt {
                        if ($null -eq (Get-Variable -Name __AIPredictor_Registered -Scope Global -ErrorAction SilentlyContinue)) {
                            try {
                                Register-AIPredictor *> $null
                                if ($?) {
                                    Write-Host "✅ AIPredictor 已成功注册" -ForegroundColor Green
                                }
                            } catch {
                                Write-Warning "[!] 注册 AIPredictor 失败: $($_.Exception.Message)"
                            }
                            $global:__AIPredictor_Registered = $true
                        }
                        # 执行原始 Oh My Posh 提示符
                        & $originalPrompt
                    } -Force

                    Write-Host "    ⏳ 将在首次显示提示符时自动注册 AIPredictor..." -ForegroundColor Yellow
                }
                catch {
                    Write-Warning "[!] 包装 prompt 函数失败: $_"
                }
            }
        } catch {
            Write-Warning "[!] AIPredictor 加载失败: $_"
            Write-Host "    路径: $aiPredictorPath" -ForegroundColor Red
        }
    } else {
        Write-Host "未找到 AIPredictor 插件 → " -NoNewline
        Write-Host $aiPredictorPath -ForegroundColor DarkGray
    }
}
catch {
    Write-Error "[模块加载失败] $_"
    if ($module) {
        Write-Host "    错误模块: $module" -ForegroundColor Red
    }
    exit 8
}
#endregion

#region 智能预测配置
try {
    # 1. 检查 PSReadLine 是否可用
    $psrlModule = Get-Module PSReadLine -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $psrlModule) {
        Write-Warning "PSReadLine 未安装，跳过智能预测配置。"
        return
    }

    # 2. 确保 PSReadLine 已加载
    if (-not (Get-Module PSReadLine)) {
        Import-Module PSReadLine -Force
    }

    # 3. 检查插件支持能力
    $supportsPlugin = ([version]$psrlModule.Version -ge [version]"2.2.0")
    if (-not $supportsPlugin) {
        Write-Warning "PSReadLine 版本过低（当前 v$($psrlModule.Version)），需 ≥ 2.2.0 才支持 Plugin 预测。"
        Set-PSReadLineOption -PredictionSource History
        Set-PSReadLineOption -MaximumHistoryCount 100000
        Set-PSReadLineOption -PredictionViewStyle InlineView
        Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
        return
    }

    # 4. 检测已加载的预测插件
    $loadedPlugins = @()
    if (Get-Module Az.Tools.Predictor) { $loadedPlugins += "Az.Tools.Predictor" }
    if (Get-Module AIPredictor) { $loadedPlugins += "AIPredictor" }

    # 5. 设置预测源
    if ($loadedPlugins.Count -gt 0) {
        Set-PSReadLineOption -PredictionSource HistoryAndPlugin
        Write-Host "已启用智能预测（插件: $($loadedPlugins -join ', ')）" -ForegroundColor Green
    } else {
        Set-PSReadLineOption -PredictionSource History
        Write-Host "未检测到预测插件，仅启用历史记录预测" -ForegroundColor Yellow
    }

    # 6. 统一设置其他 PSReadLine 选项（合理值）
    Set-PSReadLineOption -MaximumHistoryCount 100000
    Set-PSReadLineOption -PredictionViewStyle InlineView
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete

    # 7. 用户提示（如果启用了 AI）
    if ($loadedPlugins -contains "AIPredictor") {
        $global:DebugAIPredictor = $true
        Write-Host "💡 提示：输入自然语言（如 'delete old logs'）可触发 AI 预测" -ForegroundColor Cyan
    }
}
catch {
    Write-Error "[智能预测配置失败] $_"
    # 安全回退
    try {
        Set-PSReadLineOption -PredictionSource History
        Set-PSReadLineOption -MaximumHistoryCount 10000
        Set-PSReadLineOption -PredictionViewStyle InlineView
    }
    catch {
        # 静默
    }
}
#endregion

$global:DebugAIPredictor = $true

Write-Host "`n配置文件加载完成`n" -ForegroundColor Green