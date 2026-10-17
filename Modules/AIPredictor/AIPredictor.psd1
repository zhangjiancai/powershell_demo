@{
    RootModule        = 'AIPredictor.psm1'
    ModuleVersion     = '1.5.0'
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
            ReleaseNotes = 'v1.5.0：多候选方案、高风险命令安全刹车（Tab 拦截 / Alt+P 二次确认）、隐私日志（默认不记输入原文）、用量统计 Get-AIPredictorStatus -Stats'
        }
    }
}
