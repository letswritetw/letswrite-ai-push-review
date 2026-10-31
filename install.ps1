<#
  AI code review 安裝（Windows）：每台電腦跑一次，之後 push 時都會在背景審查分支的改動。
  用法：雙擊 install.cmd
        install.cmd -Engine codex          指定用 codex（預設自動偵測，claude 優先）
        install.cmd -Trigger manual        push 不自動審，要審時執行 git ai-review
        install.cmd -Webhook <網址>        指定 n8n webhook（沒指定就只把報告存在本機）
        install.cmd -RemotePattern <樣式>  只審 origin 網址符合的 repo，例如 "*git.example.com*"（預設全部）
        install.cmd -Uninstall             移除
  需求：Git 2.54 以上（設定式 hook）、claude 或 codex 已用訂閱登入。
  注意：本檔需存成 UTF-8 with BOM，否則 Windows PowerShell 5.1 讀中文會亂碼。
#>
param(
  [ValidateSet('', 'claude', 'codex')] [string]$Engine = '',
  [ValidateSet('push', 'manual')] [string]$Trigger = 'push',
  [string]$Webhook = '',
  [string]$RemotePattern = '*',
  [string]$InstallDir = "$env:USERPROFILE\.ai-review",
  [switch]$Uninstall
)

# 本檔用 PowerShell 5.1 的參數傳遞方式；用 pwsh 7 跑時切回同樣行為
if ($PSVersionTable.PSVersion.Major -ge 7) { $PSNativeCommandArgumentPassing = 'Legacy' }

function Fail($msg) { Write-Host "安裝失敗：$msg" -ForegroundColor Red; exit 1 }
function Has($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

if ($Uninstall) {
  cmd /c "git config --global --remove-section hook.ai-review 2>nul"
  cmd /c "git config --global --remove-section ai-review 2>nul"
  cmd /c "git config --global --unset alias.ai-review 2>nul"
  Write-Host "已移除 git 設定。審查紀錄還留在 $InstallDir，不需要可以手動刪除。"
  exit 0
}

# 1. Git 版本
if (-not (Has git)) { Fail '找不到 git，請先安裝 Git for Windows' }
function GitVersion { [version]((git --version) -replace '^git version (\d+\.\d+\.\d+).*', '$1') }
if ((GitVersion) -lt [version]'2.54.0') {
  Write-Host "Git $(GitVersion) 太舊，嘗試用 winget 升級…"
  if (Has winget) { winget upgrade --id Git.Git -e --silent --accept-source-agreements }
  if ((GitVersion) -lt [version]'2.54.0') { Fail 'Git 需要 2.54 以上，請手動升級 Git for Windows 後重跑' }
}

# 2. 審查引擎（訂閱登入）
function ClaudeOk { (Has claude) -and ((claude auth status 2>$null | Out-String) -match '"loggedIn":\s*true') }
function CodexOk { (Has codex) -and ((cmd /c "codex login status 2>&1" | Out-String) -match 'Logged in') }
if (-not $Engine) {
  if (ClaudeOk) { $Engine = 'claude' } elseif (CodexOk) { $Engine = 'codex' }
  else { Fail 'claude 和 codex 都沒有登入，請先執行 claude（登入訂閱帳號）或 codex login' }
} elseif ($Engine -eq 'claude' -and -not (ClaudeOk)) { Fail 'claude 沒有登入，請先執行 claude 登入訂閱帳號' }
elseif ($Engine -eq 'codex' -and -not (CodexOk)) { Fail 'codex 沒有登入，請先執行 codex login' }

# 3. 複製腳本與 skill 備份（review.sh 優先用 ~/.claude/skills 或 ~/.codex/skills 裡的 ai-code-review，找不到才用這份）
$skillSrc = Join-Path $PSScriptRoot 'skills\ai-code-review\SKILL.md'
New-Item -ItemType Directory -Force $InstallDir | Out-Null
# review.sh 要 LF、無 BOM，否則 sh 跑不動；.NET 的 ReadAllText/WriteAllText 預設就是 UTF-8 無 BOM
$sh = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'review.sh')) -replace "`r`n", "`n"
[IO.File]::WriteAllText((Join-Path $InstallDir 'review.sh'), $sh)
Copy-Item $skillSrc (Join-Path $InstallDir 'SKILL.md') -Force

# 4. git 全域設定：push 前的 hook，加上手動審查用的 git ai-review
$script = 'sh "' + ($InstallDir -replace '\\', '/') + '/review.sh"'
$alias = "!$script --now"
# PowerShell 5.1 不會跳脫參數裡的雙引號，要自己加
git config --global hook.ai-review.command ($script -replace '"', '\"')
git config --global --replace-all hook.ai-review.event pre-push
git config --global alias.ai-review ($alias -replace '"', '\"')
git config --global ai-review.trigger $Trigger
git config --global ai-review.engine $Engine
# PowerShell 5.1 會丟掉空字串參數，沒給 webhook 時改成移除設定
if ($Webhook) { git config --global ai-review.webhook $Webhook } else { cmd /c "git config --global --unset ai-review.webhook 2>nul" }
git config --global ai-review.remotePattern $RemotePattern
if ((git config --global hook.ai-review.command) -ne $script) { Fail "hook 指令寫入結果不符：$(git config --global hook.ai-review.command)" }
if ((git config --global alias.ai-review) -ne $alias) { Fail "git ai-review 指令寫入結果不符：$(git config --global alias.ai-review)" }

# 5. 圖形介面工具常自帶舊版 git；低於 2.54 時從它們 push 不會觸發審查，列出來提醒
$minGit = [version]'2.54.0'
$sysGit = (Get-Command git).Source
# Fork 會在所選 git.exe 的同一層找 bash.exe，系統 Git 的 cmd\ 底下沒有，要指定 bin\git.exe
$forkGit = Join-Path (Split-Path (Split-Path $sysGit)) 'bin\git.exe'
if (-not (Test-Path $forkGit)) { $forkGit = $sysGit }
function GitVer($exe) {
  if (-not $exe -or -not (Test-Path $exe)) { return $null }
  try { [version]((& $exe --version) -replace '^git version (\d+\.\d+\.\d+).*', '$1') } catch { $null }
}
function Newest($pattern) {   # 同一工具裝了多版時取最新的那個 git.exe
  Get-ChildItem $pattern -ErrorAction SilentlyContinue | Sort-Object { $v = GitVer $_.FullName; if ($v) { $v } else { [version]'0.0' } } | Select-Object -Last 1 -ExpandProperty FullName
}
$warn = @()
$forkSettings = "$env:LOCALAPPDATA\Fork\settings.json"
if (Test-Path $forkSettings) {
  # 設定裡沒指定 git 時，Fork 用自己內建的
  $p = try { (Get-Content -Raw -Encoding UTF8 $forkSettings | ConvertFrom-Json).GitInstancePath } catch { $null }
  if ($p -and (Test-Path $p -PathType Container)) { $p = Join-Path $p 'cmd\git.exe' }
  if (-not $p) { $p = Newest "$env:LOCALAPPDATA\Fork\gitInstance\*\cmd\git.exe" }
  $v = GitVer $p
  if (-not $v -or $v -lt $minGit) { $warn += "Fork（Git $v）：Preferences → Git → Git Instance 改指定 $forkGit" }
}
if (Test-Path "$env:LOCALAPPDATA\SourceTree\SourceTree.exe") {
  # 看不出使用者選了內建還是系統 Git，內建版本太舊就提醒
  $v = GitVer (Newest "$env:LOCALAPPDATA\Atlassian\SourceTree\git_local\cmd\git.exe")
  if (-not $v -or $v -lt $minGit) { $warn += "SourceTree（內建 Git $v）：Tools → Options → Git → Git Version 選 System；已經改過可以忽略" }
}
$v = GitVer (Newest "$env:LOCALAPPDATA\GitHubDesktop\app-*\resources\app\git\cmd\git.exe")
if ($v -and $v -lt $minGit) { $warn += "GitHub Desktop（內建 Git $v）：不能換 git，請改用 VS Code、Fork 或命令列 push" }
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
  # VS 用自己內建的 Git，沒有改用系統 Git 的選項，要靠更新 VS 換新版
  foreach ($vs in (& $vswhere -all -prerelease -format json | Out-String | ConvertFrom-Json)) {
    $v = GitVer (Join-Path $vs.installationPath 'Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\Git\cmd\git.exe')
    if ($v -and $v -lt $minGit) { $warn += "$($vs.displayName)（內建 Git $v）：用 Visual Studio Installer 更新到最新版" }
  }
}

Write-Host ''
$hookTarget = if ($Webhook) { $Webhook } else { '未設定（報告只存在本機）' }
$repoScope = if ($RemotePattern -eq '*') { '全部' } else { $RemotePattern }
Write-Host "安裝完成：引擎 $Engine，觸發方式 $Trigger，審查的 repo：$repoScope，webhook：$hookTarget" -ForegroundColor Green
if ($Trigger -eq 'push') {
  Write-Host '之後 push 時，會在背景審查這個分支的改動；只改文件、圖片時自動跳過。'
  Write-Host '單次跳過：最新的 commit 訊息寫 skip'
} else {
  Write-Host 'push 不會自動審查；要審時在專案資料夾執行：git ai-review'
}
Write-Host "改觸發方式：git config --global ai-review.trigger push 或 manual"
Write-Host "紀錄在 $InstallDir\review.log"
if ($warn) {
  Write-Host ''
  Write-Host "注意：下列工具用的 Git 低於 $minGit，從它們 push 不會觸發審查：" -ForegroundColor Yellow
  $warn | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
