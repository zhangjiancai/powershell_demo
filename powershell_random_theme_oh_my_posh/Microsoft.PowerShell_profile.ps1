##oh-my-posh init pwsh | Invoke-Expression
#winget install JanDeDobbeleer.OhMyPosh -s winget
#winget upgrade JanDeDobbeleer.OhMyPosh -s winget

$OhMyPosh_local = (Get-Command oh-my-posh).Source

# 检查Google Chrome是否已安装
#$chromePath = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
if (Test-Path $OhMyPosh_local) {
    Write-Output "OhMyPosh已安装"
    Write-Output "安装位置：$($OhMyPosh_local)"
} else {
    Write-Output "OhMyPosh未安装,准备安装"
    winget install JanDeDobbeleer.OhMyPosh -s winget --rainbow
}

#检查计算器是否在运行
#if (-not (Get-Process -Name "calc" -ErrorAction SilentlyContinue)) {
    #如果计算器没有运行，则执行以下命令
#    echo "Calculator is not running"
#}
#else {
    #如果计算器正在运行，则执行以下命令
#    echo "Calculator is running"
#}


#自动主题切换来自https://zhuanlan.zhihu.com/p/541486363

$theme = Get-ChildItem $env:UserProfile\\AppData\\Local\\Programs\\oh-my-posh\\themes\\ | Get-Random
Write-Output "hello! today's lucky theme is: $theme 😂😊:)"
oh-my-posh --init --shell pwsh --config $theme.FullName | Invoke-Expression

#oh-my-posh init pwsh --config 'C:\Users\<用户名>\AppData\Local\Programs\oh-my-posh\themes\ys.omp.json' | Invoke-Expression
Import-Module Az.Tools.Predictor
Set-PSReadLineOption -PredictionSource HistoryAndPlugin
Import-Module Az.Tools.Predictor
Set-PSReadLineOption -PredictionSource HistoryAndPlugin
Import-Module Az.Tools.Predictor
Set-PSReadLineOption -PredictionSource HistoryAndPlugin

function _sudo {
    $ss = "$args ; pause"
    Start-Process powershell -Verb runAs -ArgumentList $ss
}
set-alias  -name sudo -value _sudo
