$OhMyPosh_local = (Get-Command oh-my-posh).Source

if (Test-Path $OhMyPosh_local) {
    Write-Output "OhMyPosh已安装"
    Write-Output "安装位置：$($OhMyPosh_local)"
} else {
    Write-Output "OhMyPosh未安装,准备安装"
    winget install JanDeDobbeleer.OhMyPosh -s winget --rainbow
}

#自动主题切换来自https://zhuanlan.zhihu.com/p/541486363

$theme = Get-ChildItem $env:UserProfile\\AppData\\Local\\Programs\\oh-my-posh\\themes\\ | Get-Random
Write-Output "hello! today's lucky theme is: $theme 😂😊:)"
oh-my-posh --init --shell pwsh --config $theme.FullName | Invoke-Expression

Set-PSReadLineOption -HistorySavePath "$env:UserProfile\Documents\PowerShell\PSReadLine"

Import-Module Az.Tools.Predictor
Set-PSReadLineOption -PredictionSource HistoryAndPlugin


function _sudo {
    $ss = "$args ; pause"
    Start-Process powershell -Verb runAs -ArgumentList $ss
}
set-alias  -name sudo -value _sudo

#Get-PSReadLineOption | find /N " " | findstr /r \[[0-9]\]
#(Get-PSReadLineOption | find /N " " | findstr /r \[[0-9]\]) | Select-Object -Index 3
Write-Output "HistorySavePath is $((Get-PSReadLineOption).HistorySavePath)"