$link = New-Item -ItemType SymbolicLink -Path "D:\OneDrive\OneDrive - tcc72\文档\PowerShell\PowerShell" -Target "C:\Users\zjc20\AppData\Roaming\Microsoft\Windows\PowerShell"
$link | Select-Object LinkType, Target
