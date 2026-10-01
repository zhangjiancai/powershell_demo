<#
.SYNOPSIS
    提交前敏感信息检查：发现疑似 API Key / 令牌 / 私钥就阻止提交。
.DESCRIPTION
    默认检查暂存区（pre-commit 钩子会调用它）；也可以手动检查所有被跟踪文件。
    命中时退出码为 1，并给出文件名、行号和打码后的内容。
.EXAMPLE
    pwsh -File Scripts/Test-NoSecrets.ps1 -Staged
    pwsh -File Scripts/Test-NoSecrets.ps1 -All
#>
[CmdletBinding()]
param(
    [switch]$Staged,
    [switch]$All,
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'
if (-not $Staged -and -not $All -and -not $Path) { $Staged = $true }

# 疑似密钥的文本特征
$patterns = @(
    @{ Name = 'API Key (sk-)';  Regex = 'sk-[A-Za-z0-9_\-]{20,}' }
    @{ Name = 'GitHub 令牌';    Regex = '(gho_|ghp_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]{20,}' }
    @{ Name = 'AWS Access Key'; Regex = 'AKIA[0-9A-Z]{16}' }
    @{ Name = '私钥内容';       Regex = '-----BEGIN [A-Z ]*PRIVATE KEY-----' }
    @{ Name = 'Bearer 令牌';    Regex = '(?i)bearer\s+[A-Za-z0-9\-\._]{20,}' }
    @{ Name = '密钥赋值';       Regex = '(?i)(api[_-]?key|apikey|access[_-]?token|client[_-]?secret|password|passwd)\s*[=:]\s*[\x22\x27]?([A-Za-z0-9_\-\.]{16,})' }
)

# 模板 / 占位符放过（config.example.json 就是这种）
$placeholder = '你的|在这里|placeholder|example|sample|xxxx|\*\*\*|<[^>]*>|REDACTED'

# 不该入库的文件名（.gitignore 之外的兜底）
$badNames = @(
    @{ Name = '真实配置文件'; Regex = '(^|/)config\.json$' }
    @{ Name = '密钥/证书';    Regex = '\.(key|pem|pfx|p12|keystore)$' }
    @{ Name = '环境变量文件'; Regex = '(^|/)\.env' }
    @{ Name = '凭据文件';     Regex = '(?i)(^|/)(credentials?|secrets?)[^/]*\.(json|ya?ml|txt|xml|ps1|psm1|ini|config)$' }
    @{ Name = 'SSH 私钥';     Regex = '(^|/)id_(rsa|ed25519|ecdsa)$' }
)

function Get-FileText([string]$file) {
    if ($Staged -and -not $All -and -not $Path) {
        $text = git show (':' + $file) 2>$null
        return ($text -join [Environment]::NewLine)
    }
    if (Test-Path -LiteralPath $file) { return (Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue) }
    return ''
}

$files = if ($Path) { $Path } elseif ($All) { @(git ls-files) } else { @(git diff --cached --name-only --diff-filter=ACM) }

$problems = @()
foreach ($file in $files) {
    if ([string]::IsNullOrWhiteSpace($file)) { continue }

    foreach ($bad in $badNames) {
        if ($file -match $bad.Regex) { $problems += ('[文件名] ' + $file + ' —— ' + $bad.Name); break }
    }

    $content = Get-FileText $file
    if (-not $content) { continue }

    $lineNo = 0
    foreach ($line in ($content -split '\r?\n')) {
        $lineNo++
        foreach ($p in $patterns) {
            if ($line -notmatch $p.Regex) { continue }
            if ($line -match $placeholder) { continue }
            $shown = $line.Trim()
            if ($shown.Length -gt 90) { $shown = $shown.Substring(0, 90) + '...' }
            $shown = $shown -replace '([A-Za-z0-9_\-]{6})[A-Za-z0-9_\-]{10,}', '$1***'
            $problems += ('[' + $p.Name + '] ' + $file + ':' + $lineNo + '  ' + $shown)
            break
        }
    }
}

if ($problems.Count -gt 0) {
    Write-Host ''
    Write-Host '✘ 检测到疑似敏感信息，已阻止提交：' -ForegroundColor Red
    $problems | ForEach-Object { Write-Host ('   ' + $_) -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '  确认是误报可加 --no-verify 跳过：git commit --no-verify' -ForegroundColor DarkGray
    exit 1
}

Write-Host '✔ 敏感信息检查通过' -ForegroundColor Green
exit 0
