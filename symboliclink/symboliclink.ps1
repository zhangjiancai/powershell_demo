$link = New-Item -ItemType SymbolicLink -Path "D:\OneDrive\OneDrive - <组织名>\文档\PowerShell\PowerShell" -Target "$env:APPDATA\Microsoft\Windows\PowerShell"
$link | Select-Object LinkType, Target
