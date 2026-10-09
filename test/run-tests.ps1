<#
    auto-hdr.lua 逻辑自测

    用假的 HDRCmd（stub .bat）驱动真实的 mpv 事件流，全程不碰真实显示器，
    可以随时反复运行。覆盖：文件名预判、元数据判定、快路径、防抖、状态复核、
    命令失败、无 HDR 显示器、片尾关闭、退出关闭。

    用法：
        powershell -ExecutionPolicy Bypass -File test\run-tests.ps1
        powershell -ExecutionPolicy Bypass -File test\run-tests.ps1 -MpvPath "D:\mpv\mpv.com"
        powershell -ExecutionPolicy Bypass -File test\run-tests.ps1 -KeepTemp   # 保留现场便于排查

    真实 HDR 切换的手工清单见 test\README.md。
#>
param(
    [string]$MpvPath = "C:\Program Files\mpv\mpv.com",
    [switch]$KeepTemp
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptSrc = Join-Path $repoRoot "auto-hdr.lua"
if (-not (Test-Path $scriptSrc)) { throw "找不到 $scriptSrc" }
if (-not (Test-Path $MpvPath))   { throw "找不到 mpv：$MpvPath（用 -MpvPath 指定）" }

# 工作目录放在无空格的路径下，避免命令行传参被空格拆坏
$work = Join-Path $env:TEMP "auto-hdr-test"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---------- 1. 假 HDRCmd：记录调用 + 维护状态 + 可切换失败模式 ----------
$stubPath    = Join-Path $work "hdr-cmd.bat"
$callsPath   = Join-Path $work "calls.log"
$statePath   = Join-Path $work "state.on"
$modeFail    = Join-Path $work "mode-fail"
$modeNoHdr   = Join-Path $work "mode-unsupported"

$stubSource = Join-Path $PSScriptRoot "stub-hdrcmd.bat"
if (-not (Test-Path $stubSource)) { throw "找不到 $stubSource" }
Copy-Item $stubSource $stubPath -Force

# ---------- 2. 退出助手：N 秒后退出，模拟用户按 q / 点 ✕ ----------
$quitHelper = Join-Path $work "testquit.lua"
$stopHelper = Join-Path $work "teststop.lua"
function Write-QuitHelper([int]$Seconds) {
    $lua = "mp.add_timeout($Seconds, function() mp.command(`"quit`") end)`r`n"
    [System.IO.File]::WriteAllText($quitHelper, $lua, $utf8NoBom)
}
function Write-StopHelper([int]$Seconds) {
    $lua = "mp.add_timeout($Seconds, function() mp.command(`"stop`") end)`r`n"
    [System.IO.File]::WriteAllText($stopHelper, $lua, $utf8NoBom)
}

# ---------- 3. 测试用的 auto-hdr.lua 副本（指向 stub、缩短握手、开 debug）----------
$testScript = Join-Path $work "auto-hdr.lua"
$src = [System.IO.File]::ReadAllText($scriptSrc, [System.Text.Encoding]::UTF8)
$patched = $src.Replace('hdr_cmd_path = "C:\\Program Files\\mpv\\HDRCmd.exe"', 'hdr_cmd_path = "' + ($stubPath -replace '\\','/') + '"')
$patched = $patched.Replace('debug = false', 'debug = true')
$patched = $patched.Replace('handshake_delay_on = 3.8', 'handshake_delay_on = 0.3')
$patched = $patched.Replace('handshake_delay_off = 3.8', 'handshake_delay_off = 0.3')
if ($patched -eq $src) { throw "补丁没生效：请检查脚本里的 options 默认值是否被改动过" }
[System.IO.File]::WriteAllText($testScript, $patched, $utf8NoBom)

# ---------- 4. 测试媒体 ----------
function New-SilentWav([string]$Path, [int]$Seconds) {
    $rate = 8000; $samples = $rate * $Seconds
    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $dataLen = $samples * 2
    $bw.Write([char[]]"RIFF"); $bw.Write([int](36 + $dataLen)); $bw.Write([char[]]"WAVE")
    $bw.Write([char[]]"fmt ");  $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]1)
    $bw.Write([int]$rate); $bw.Write([int]($rate * 2)); $bw.Write([int16]2); $bw.Write([int16]16)
    $bw.Write([char[]]"data"); $bw.Write([int]$dataLen)
    $bw.Write((New-Object byte[] $dataLen))
    $bw.Close(); $fs.Close()
}
New-SilentWav (Join-Path $work "movie.HDR.wav") 3
New-SilentWav (Join-Path $work "ep2.DoVi.wav")  3
New-SilentWav (Join-Path $work "plain.wav")     3
New-SilentWav (Join-Path $work "long.HDR.wav")  30

# 一段真实视频（音频文件没有 video-params，测不到元数据判定）
$testVideo = "av://lavfi:testsrc=size=64x64:rate=5:duration=2"

# ---------- 工具函数 ----------
function Reset-Stub {
    Remove-Item $callsPath, $statePath, $modeFail, $modeNoHdr -Force -ErrorAction SilentlyContinue
}
function Set-StubMode([string]$Mode) {
    if ($Mode -eq "fail")        { New-Item -ItemType File -Path $modeFail  | Out-Null }
    if ($Mode -eq "unsupported") { New-Item -ItemType File -Path $modeNoHdr | Out-Null }
}
function Get-Calls {
    if (-not (Test-Path $callsPath)) { return @() }
    return @(Get-Content $callsPath | ForEach-Object { $_.Trim().Trim('[', ']') } |
             Where-Object { $_ -ne "" })
}
function Invoke-Mpv([string[]]$Files, [int]$QuitAfter, [string[]]$Extra, [int]$StopAfter = 0) {
    Write-QuitHelper $QuitAfter
    $outFile = Join-Path $work "mpv-out.txt"
    $errFile = Join-Path $work "mpv-err.txt"
    $helpers = @($quitHelper)
    if ($StopAfter -gt 0) { Write-StopHelper $StopAfter; $helpers += $stopHelper }
    $mpvArgs = @("--no-config", "--vo=null", "--ao=null", "--keep-open=yes",
                 "--script=$testScript") + ($helpers | ForEach-Object { "--script=$_" }) + $Extra + $Files
    $p = Start-Process -FilePath $MpvPath -ArgumentList $mpvArgs -NoNewWindow -PassThru `
                       -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    if (-not $p.WaitForExit(30000)) { $p.Kill(); return @("[超时] mpv 未在 30 秒内退出") }
    $text = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8) + "`n" +
            [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8)
    return @($text -split "`r?`n" | Where-Object { $_ -match '^\[auto_hdr\]' } |
             ForEach-Object { $_ -replace '^\[auto_hdr\]\s*', '' })
}

$script:results = @()
function Add-Result([string]$Name, [bool]$Pass, [string]$Detail) {
    $script:results += [pscustomobject]@{ Name = $Name; Pass = $Pass; Detail = $Detail }
}

function Test-Case {
    param(
        [string]$Name,
        [string[]]$Media = @(),
        [string]$Video = "",
        [string]$Mode = "ok",
        [int]$QuitAfter = 8,
        [int]$StopAfter = 0,
        [string[]]$Extra = @(),
        [string[]]$Expect = @(),
        [string[]]$ExpectAbsent = @(),
        [string]$CallsMatch = "",
        [string]$CallsAbsent = ""
    )
    Reset-Stub
    Set-StubMode $Mode
    $files = @()
    if ($Video) { $files += $Video }
    $files += ($Media | ForEach-Object { Join-Path $work $_ })

    $log = Invoke-Mpv -Files $files -QuitAfter $QuitAfter -Extra $Extra -StopAfter $StopAfter
    $logText = ($log -join "`n")
    $calls = Get-Calls
    $callsText = ($calls -join ",")

    $problems = @()
    foreach ($e in $Expect)       { if ($logText -notlike "*$e*") { $problems += "日志缺少「$e」" } }
    foreach ($e in $ExpectAbsent) { if ($logText -like    "*$e*") { $problems += "日志不该出现「$e」" } }
    if ($CallsMatch  -and $callsText -notmatch $CallsMatch)  { $problems += "调用序列不符：期望匹配 /$CallsMatch/，实际 [$callsText]" }
    if ($CallsAbsent -and $callsText -match    $CallsAbsent) { $problems += "不该出现该调用：/$CallsAbsent/ 命中 [$callsText]" }

    $detail = ""
    if ($problems.Count -gt 0) {
        $detail = ($problems -join "；") + "`n    实际调用：[$callsText]`n    日志尾部：" +
                  (($log | Select-Object -Last 4 | ForEach-Object { "`n      $_" }) -join "")
    } else {
        $detail = "调用 [$callsText]"
    }
    Add-Result $Name ($problems.Count -eq 0) $detail
}

# ---------- 用例 ----------
Write-Host "工作目录：$work" -ForegroundColor DarkGray

Test-Case -Name "HDR 文件名 → 预判开启 HDR" -Media @("movie.HDR.wav") `
    -Expect @("HDR 已开启（文件名预判") -ExpectAbsent @("元数据检测") `
    -CallsMatch "^status,on"

Test-Case -Name "DoVi 文件名 → 预判开启 HDR" -Media @("ep2.DoVi.wav") `
    -Expect @("HDR 已开启（文件名预判") `
    -CallsMatch "^status,on"

Test-Case -Name "纯 SDR 视频 → 走快路径，零外部调用" -Video $testVideo `
    -Expect @("元数据检测：gamma=srgb", "-> sdr") `
    -CallsMatch "^$"

Test-Case -Name "音轨文件 → 元数据超时后按文件名兜底判 SDR" -Media @("plain.wav") `
    -Expect @("-> wait", "无需处理（元数据超时") `
    -CallsMatch "^$"

Test-Case -Name "HDR → SDR 连播 → 中间不夹多余的关/开" -Media @("movie.HDR.wav", "plain.wav") `
    -Expect @("HDR 已开启（文件名预判", "HDR 已关闭") `
    -CallsMatch "^status,on,status,off$"

Test-Case -Name "命令失败 → 不谎报成功（回读真实状态）" -Media @("movie.HDR.wav") -Mode "fail" `
    -Expect @("HDR 开启失败") -ExpectAbsent @("HDR 已开启") `
    -CallsMatch "^status,on,status"

Test-Case -Name "无 HDR 显示器(unsupported) → 整体旁路" -Media @("movie.HDR.wav") -Mode "unsupported" `
    -Expect @("退出码 2", "跳过本次切换") -ExpectAbsent @("HDR 已开启") `
    -CallsMatch "^status$" -CallsAbsent "on|off"

Test-Case -Name "播到结尾 → 保持 HDR 不关（便于拖回去回看）" -Media @("movie.HDR.wav") -QuitAfter 10 `
    -Expect @("mpv 退出：关闭系统 HDR") `
    -ExpectAbsent @("播放结束且无新视频：关闭系统 HDR") `
    -CallsMatch "^status,on,off$"

Test-Case -Name "手动 stop（文件被卸载）→ 防抖倒计时后关闭" -Media @("long.HDR.wav") -StopAfter 3 -QuitAfter 10 -Extra @("--idle=yes") `
    -Expect @("播放结束且无新视频：关闭系统 HDR") `
    -CallsMatch "^status,on,off$"

Test-Case -Name "播放中退出(✕/q) → 立即同步关闭" -Media @("long.HDR.wav") -QuitAfter 3 `
    -Expect @("mpv 退出：关闭系统 HDR") `
    -CallsMatch "^status,on,off$"

# ---------- 汇总 ----------
Write-Host ""
$pass = @($script:results | Where-Object Pass).Count
$fail = @($script:results | Where-Object { -not $_.Pass }).Count

$i = 0
foreach ($r in $script:results) {
    $i++
    $tag = if ($r.Pass) { "PASS" } else { "FAIL" }
    $color = if ($r.Pass) { "Green" } else { "Red" }
    Write-Host ("[{0}/{1}] {2,-46} {3}" -f $i, $script:results.Count, $r.Name, $tag) -ForegroundColor $color
    if (-not $r.Pass) { Write-Host ("        " + $r.Detail) -ForegroundColor Yellow }
    elseif ($r.Detail) { Write-Host ("        " + $r.Detail) -ForegroundColor DarkGray }
}

Write-Host ""
if ($fail -eq 0) {
    Write-Host "全部通过（$pass/$($script:results.Count)）。" -ForegroundColor Green
} else {
    Write-Host "失败 $fail 项，通过 $pass 项。" -ForegroundColor Red
}
if ($KeepTemp) { Write-Host "现场保留在：$work" -ForegroundColor DarkGray }
else { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }

exit $fail
