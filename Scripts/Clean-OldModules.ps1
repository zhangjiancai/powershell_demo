# 1. 生成清理脚本
$cleanScript = {
  # 获取所有已安装模块（排除系统核心模块）
  $allModules = Get-InstalledModule | Where-Object { 
    $_.Name -notmatch "Microsoft\.PowerShell\..*|PSReadLine" 
  }

  # 按模块名称分组处理
  $allModules | Group-Object Name | ForEach-Object {
    $moduleGroup = $_.Group
    $latestVersion = $moduleGroup | Sort-Object Version -Descending | Select-Object -First 1

    # 删除旧版本
    $moduleGroup | Where-Object { $_.Version -ne $latestVersion.Version } | ForEach-Object {
      Write-Host "正在删除旧模块: $($_.Name) v$($_.Version)" -ForegroundColor Yellow
      $_ | Uninstall-Module -Force -ErrorAction SilentlyContinue
    }
  }
}

# 2. 执行清理（需要管理员权限时以管理员身份运行）
Invoke-Command -ScriptBlock $cleanScript