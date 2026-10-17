@{
    RootModule        = 'AIPredictor.psm1'
    ModuleVersion     = '1.4.0'
    GUID              = '27aafe69-0656-454d-b385-2396f8e9251d'
    Author            = 'zhangjiancai'
    Description       = 'AI 命令预测（PowerShell 引擎 ICommandPredictor 子系统）：Tab 出建议 / Alt+P 直接问'
    PowerShellVersion = '7.2'

    FunctionsToExport = @(
        'Register-AIPredictor',
        'Unregister-AIPredictor',
        'Get-AIPredictorSuggestion',
        'Get-AIPredictorStatus',
        'Test-AIPredictor'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('AI', 'Prediction', 'PSReadLine', 'DeepSeek')
            ProjectUri   = 'https://github.com/zhangjiancai/powershell_demo'
            ReleaseNotes = 'v1.4.0：只对自然语言发请求（不再被命令编辑触发）、拒答/说明文字不再当命令、多行脚本安全处理、缓存 TTL、请求去重'
        }
    }
}
