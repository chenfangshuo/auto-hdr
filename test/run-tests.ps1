<#
    auto-hdr.lua 逻辑自测

    用假的 HDRCmd（运行时编译出的 stub.exe）驱动真实的 mpv 事件流，全程不碰真实显示器，
    可以随时反复运行。覆盖：文件名预判、元数据判定、快路径、防抖、状态复核、命令失败、
    无 HDR 显示器、片尾关闭、退出关闭、路径写错、停止播放/切集的回调竞态、暂停所有权、
    跨文件物理握手（慢握手副本）、退出时在途 on。

    用法：
        powershell -File test\run-tests.ps1
        powershell -File test\run-tests.ps1 -MpvPath "D:\mpv\mpv.com"
        powershell -File test\run-tests.ps1 -KeepTemp   # 保留现场便于排查

    替身为什么是编译出来的 exe：脚本直接调用 HDRCmd.exe（mpv 用 CreateProcessW 拉起），
    而 CreateProcess 只认可执行映像，.bat 会直接失败。见 stub-hdrcmd.cs 的说明。

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

# ---------- 1. 假 HDRCmd：编译成 exe + 可切换的失败模式 ----------
$stubExe     = Join-Path $work "hdr-cmd.exe"
$callsPath   = Join-Path $work "calls.log"
$statePath   = Join-Path $work "state.on"
$modeFail    = Join-Path $work "mode-fail"
$modeNoHdr   = Join-Path $work "mode-unsupported"
$modeOffFail = Join-Path $work "mode-off-fail"
$modeSlowOn  = Join-Path $work "mode-slow-on"
$modeSlowSt  = Join-Path $work "mode-slow-status"
$modeSlowOff = Join-Path $work "mode-slow-off"
$modeSlowExitOn = Join-Path $work "mode-slow-exit-on"
$modeSlowExitSt = Join-Path $work "mode-slow-exit-status"
$modeSlowReread = Join-Path $work "mode-slow-reread"
$modeHangOn = Join-Path $work "mode-hang-on"
$attemptPath = Join-Path $work "on-attempt"

$stubSource = Join-Path $PSScriptRoot "stub-hdrcmd.cs"
if (-not (Test-Path $stubSource)) { throw "找不到 $stubSource" }
$stubCode = [System.IO.File]::ReadAllText($stubSource, [System.Text.Encoding]::UTF8)

function New-StubExe([string]$Output) {
    # 首选 .NET Framework 自带的 C# 编译器（Win10/11 默认存在，输出的是真 exe）
    $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (Test-Path $csc) {
        $csFile = [System.IO.Path]::ChangeExtension($Output, ".cs")
        [System.IO.File]::WriteAllText($csFile, $stubCode, $utf8NoBom)
        & $csc /nologo /target:exe "/out:$Output" $csFile | Out-Null
        if (Test-Path $Output) { return }
        Write-Host "csc.exe 编译失败，改用 Add-Type" -ForegroundColor DarkYellow
    }
    # 回退：Add-Type（Windows PowerShell 5.1 支持 -OutputType ConsoleApplication）
    try {
        Add-Type -TypeDefinition $stubCode -OutputAssembly $Output -OutputType ConsoleApplication -ErrorAction Stop
    } catch {
        throw "无法生成测试替身（csc.exe 与 Add-Type 都不可用）：$($_.Exception.Message)"
    }
}
New-StubExe $stubExe

# ---------- 2. 助手脚本：定时退出 / 停止 / 切集 / 打印暂停状态 ----------
$quitHelper  = Join-Path $work "testquit.lua"
$stopHelper  = Join-Path $work "teststop.lua"
$nextHelper  = Join-Path $work "testnext.lua"
$probeHelper = Join-Path $work "testprobe.lua"
function Write-QuitHelper([int]$Seconds) {
    $lua = "mp.add_timeout($Seconds, function() mp.command(`"quit`") end)`r`n"
    [System.IO.File]::WriteAllText($quitHelper, $lua, $utf8NoBom)
}
function Write-StopHelper([int]$Seconds) {
    $lua = "mp.add_timeout($Seconds, function() mp.command(`"stop`") end)`r`n"
    [System.IO.File]::WriteAllText($stopHelper, $lua, $utf8NoBom)
}
function Write-NextHelper([double]$Seconds) {
    $lua = "mp.add_timeout($Seconds, function() mp.command(`"playlist-next`") end)`r`n"
    [System.IO.File]::WriteAllText($nextHelper, $lua, $utf8NoBom)
}
function Write-ProbeHelper([double]$Seconds) {
    $lua = "mp.add_timeout($Seconds, function() mp.msg.info(`"TESTPROBE pause=`" .. tostring(mp.get_property_bool(`"pause`"))) end)`r`n"
    [System.IO.File]::WriteAllText($probeHelper, $lua, $utf8NoBom)
}
# 到点后加载另一个文件（模拟"防抖关闭还没落地，用户就打开了下一部"）
$loadHelper = Join-Path $work "testload.lua"
function Write-LoadHelper([double]$Seconds, [string]$File) {
    $lua = "mp.add_timeout($Seconds, function() mp.commandv(`"loadfile`", `"$($File -replace '\\','/')`") end)`r`n"
    [System.IO.File]::WriteAllText($loadHelper, $lua, $utf8NoBom)
}

# ---------- 3. 测试用的 auto-hdr.lua 副本（指向 stub、缩短握手、开 debug）----------
# 注意：脚本现在是直连 exe，路径写进 Lua 字符串里必须双反斜杠
$stubLuaPath = $stubExe -replace '\\', '\\\\'
$testScript  = Join-Path $work "auto-hdr.lua"
$src = [System.IO.File]::ReadAllText($scriptSrc, [System.Text.Encoding]::UTF8)
$patched = $src.Replace('hdr_cmd_path = "C:\\Program Files\\mpv\\HDRCmd.exe"', 'hdr_cmd_path = "' + $stubLuaPath + '"')
$patched = $patched.Replace('debug = false', 'debug = true')
# 握手值用正则改，别按字面量替换：默认值一调整，字面量匹配就会静默失效，
# 测试里每次切换会真的等 3.9 秒（拖慢，而且会打乱靠时间点构造的用例 14/15）
$patched = $patched -replace 'handshake_delay_(on|off) = [0-9.]+', 'handshake_delay_$1 = 0.3'
if ($patched -eq $src) { throw "补丁没生效：请检查脚本里的 options 默认值是否被改动过" }
if ($patched -notmatch 'handshake_delay_on = 0\.3' -or $patched -notmatch 'debug = true') {
    throw "补丁没打全：握手值或 debug 没换掉，测试会变慢/看不到日志"
}
[System.IO.File]::WriteAllText($testScript, $patched, $utf8NoBom)

# 握手 2.0 秒的副本：用来验证"物理握手跨文件有效"（0.3 秒太短，切集窗口构造不出来）。
# 同样必须保持 auto-hdr.lua 文件名，否则 mpv 的日志前缀会变成 [auto_hdr_xxx] 被过滤器丢掉。
$slowDir = Join-Path $work "slow"
New-Item -ItemType Directory -Path $slowDir | Out-Null
$testScriptSlow = Join-Path $slowDir "auto-hdr.lua"
$slow = $patched -replace 'handshake_delay_(on|off) = [0-9.]+', 'handshake_delay_$1 = 2.0'
if ($slow -notmatch 'handshake_delay_on = 2\.0') { throw "慢握手补丁没生效" }
[System.IO.File]::WriteAllText($testScriptSlow, $slow, $utf8NoBom)

# 同一份脚本、但 hdr_cmd_path 指向不存在的文件：验证"查不到状态就旁路"
# 注意两点：用正斜杠（Lua 字符串里 "\n" 是换行、"\H" 是非法转义，写反斜杠会把脚本写坏）；
# 副本要放在独立目录里并保持 auto-hdr.lua 这个文件名 —— mpv 用**文件名**给日志加前缀，
# 换个文件名日志就变成 [auto_hdr_badpath]，本脚本的日志过滤会漏掉。
$badDir = Join-Path $work "badpath"
New-Item -ItemType Directory -Path $badDir | Out-Null
$testScriptBad = Join-Path $badDir "auto-hdr.lua"
$bad = $patched.Replace('hdr_cmd_path = "' + $stubLuaPath + '"', 'hdr_cmd_path = "C:/no-such-dir/HDRCmd.exe"')
if ($bad -eq $patched) { throw "坏路径补丁没生效" }
[System.IO.File]::WriteAllText($testScriptBad, $bad, $utf8NoBom)

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
New-SilentWav (Join-Path $work "movie.HDR.wav")  3
New-SilentWav (Join-Path $work "ep2.DoVi.wav")   3
New-SilentWav (Join-Path $work "plain.wav")      3
New-SilentWav (Join-Path $work "long.HDR.wav")   30
New-SilentWav (Join-Path $work "movie.HDRip.wav") 3

# 真实视频（音频文件没有 video-params，测不到元数据判定）
$testVideo     = "av://lavfi:testsrc=size=64x64:rate=5:duration=2"
$testLongVideo = "av://lavfi:testsrc=size=64x64:rate=5:duration=30"

# ---------- 工具函数 ----------
function Reset-Stub {
    Remove-Item $callsPath, $statePath, $attemptPath, $modeFail, $modeNoHdr, $modeOffFail, $modeSlowOn, `
        $modeSlowSt, $modeSlowOff, $modeSlowExitOn, $modeSlowExitSt, $modeSlowReread, $modeHangOn `
        -Force -ErrorAction SilentlyContinue
}
function Set-StubMode([string]$Mode) {
    # 支持逗号分隔同时开多个模式（例如 "slowexitstatus,slowoff"）
    $modes = $Mode -split ','
    if ($modes -contains "fail")            { New-Item -ItemType File -Path $modeFail    | Out-Null }
    if ($modes -contains "unsupported")     { New-Item -ItemType File -Path $modeNoHdr   | Out-Null }
    if ($modes -contains "offfail")         { New-Item -ItemType File -Path $modeOffFail | Out-Null }
    if ($modes -contains "slowon")          { New-Item -ItemType File -Path $modeSlowOn  | Out-Null }
    if ($modes -contains "slowstatus")      { New-Item -ItemType File -Path $modeSlowSt  | Out-Null }
    if ($modes -contains "slowoff")         { New-Item -ItemType File -Path $modeSlowOff | Out-Null }
    if ($modes -contains "slowexit")        { New-Item -ItemType File -Path $modeSlowExitOn | Out-Null }
    if ($modes -contains "slowexitstatus")  { New-Item -ItemType File -Path $modeSlowExitSt | Out-Null }
    if ($modes -contains "slowreread")      { New-Item -ItemType File -Path $modeSlowReread | Out-Null }
    if ($modes -contains "hangon")          { New-Item -ItemType File -Path $modeHangOn | Out-Null }
}
function Get-Calls {
    if (-not (Test-Path $callsPath)) { return @() }
    return @(Get-Content $callsPath | ForEach-Object { $_.Trim().Trim('[', ']') } |
             Where-Object { $_ -ne "" })
}
function Invoke-Mpv {
    param(
        [string[]]$Files = @(),
        [int]$QuitAfter = 8,
        [string[]]$Extra = @(),
        [int]$StopAfter = 0,
        [double]$NextAfter = 0,
        [double]$ProbeAfter = 0,
        [double]$LoadAfter = 0,
        [string]$LoadFile = "",
        [string]$ScriptPath = $testScript
    )
    Write-QuitHelper $QuitAfter
    $outFile = Join-Path $work "mpv-out.txt"
    $errFile = Join-Path $work "mpv-err.txt"
    $helpers = @($quitHelper)
    if ($StopAfter -gt 0)  { Write-StopHelper $StopAfter;   $helpers += $stopHelper }
    if ($NextAfter -gt 0)  { Write-NextHelper $NextAfter;   $helpers += $nextHelper }
    if ($ProbeAfter -gt 0) { Write-ProbeHelper $ProbeAfter; $helpers += $probeHelper }
    if ($LoadAfter -gt 0)  { Write-LoadHelper $LoadAfter $LoadFile; $helpers += $loadHelper }
    $mpvArgs = @("--no-config", "--vo=null", "--ao=null", "--keep-open=yes",
                 "--script=$ScriptPath") + ($helpers | ForEach-Object { "--script=$_" }) + $Extra + $Files
    $p = Start-Process -FilePath $MpvPath -ArgumentList $mpvArgs -NoNewWindow -PassThru `
                       -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    if (-not $p.WaitForExit(30000)) { $p.Kill(); return @("[超时] mpv 未在 30 秒内退出") }
    $text = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8) + "`n" +
            [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8)
    return @($text -split "`r?`n" | Where-Object { $_ -match '^\[(auto_hdr|testprobe)\]' } |
             ForEach-Object { $_ -replace '^\[(auto_hdr|testprobe)\]\s*', '' })
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
        [string[]]$List = @(),          # 显式指定播放列表顺序（元素含 "://" 时按 URL 处理）
        [string]$Mode = "ok",
        [int]$QuitAfter = 8,
        [int]$StopAfter = 0,
        [double]$NextAfter = 0,
        [double]$ProbeAfter = 0,
        [double]$LoadAfter = 0,
        [string]$LoadFile = "",
        [switch]$BadPath,
        [switch]$SlowHandshake,     # 用握手 2.0 秒的副本（构造跨文件握手的窗口）
        [string[]]$Extra = @(),
        [string[]]$Expect = @(),
        [string[]]$ExpectAbsent = @(),
        [string]$CallsMatch = "",
        [string]$CallsAbsent = ""
    )
    Reset-Stub
    Set-StubMode $Mode
    $files = @()
    if ($List.Count -gt 0) {
        $files = $List | ForEach-Object { if ($_ -match "://") { $_ } else { Join-Path $work $_ } }
    } else {
        if ($Video) { $files += $Video }
        $files += ($Media | ForEach-Object { Join-Path $work $_ })
    }

    $log = Invoke-Mpv -Files $files -QuitAfter $QuitAfter -Extra $Extra -StopAfter $StopAfter `
                      -NextAfter $NextAfter -ProbeAfter $ProbeAfter `
                      -LoadAfter $LoadAfter -LoadFile $LoadFile `
                      -ScriptPath $(if ($BadPath) { $testScriptBad }
                                    elseif ($SlowHandshake) { $testScriptSlow }
                                    else { $testScript })
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
                  (($log | Select-Object -Last 6 | ForEach-Object { "`n      $_" }) -join "")
        if ($log.Count -eq 0) {
            $detail += "`n    （日志为空：脚本可能根本没被加载，加 -KeepTemp 后看 $work\mpv-err.txt）"
        }
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

Test-Case -Name "HDRip（SDR 片源）→ 不再误判成 HDR" -Media @("movie.HDRip.wav") `
    -Expect @("无需处理（元数据超时") -ExpectAbsent @("文件名预判") `
    -CallsMatch "^$"

Test-Case -Name "HDRCmd 路径写错 → 报错并旁路（不静默当成已开）" -Media @("movie.HDR.wav") -BadPath `
    -Expect @("系统 HDR 状态查询失败", "跳过本次切换") -ExpectAbsent @("HDR 已开启", "无缝衔接") `
    -CallsMatch "^$"

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

Test-Case -Name "off 失败 → 退出时不谎报关闭，留给 shutdown 重试" -Media @("long.HDR.wav") -Mode "offfail" -QuitAfter 3 `
    -Expect @("退出时关闭 HDR 未成功", "mpv 关闭：关闭系统 HDR") -ExpectAbsent @("HDR 已关闭") `
    -CallsMatch "^status,on,off,off$"

Test-Case -Name "停止播放打断在途的 on → 空闲不留 HDR" -Media @("long.HDR.wav") -Mode "slowon" `
    -StopAfter 1 -QuitAfter 12 -Extra @("--idle=yes") `
    -Expect @("回调返回时文件已变化", "播放结束且无新视频：关闭系统 HDR") `
    -CallsMatch "^status,on,off$"

Test-Case -Name "命令在途时切到 SDR → 旧结论不套用到新文件" -Mode "slowon" -NextAfter 0.6 `
    -QuitAfter 10 -Extra @("--idle=yes") -List @("long.HDR.wav", $testLongVideo) `
    -Expect @("回调返回时文件已变化", "HDR 已关闭（元数据") `
    -CallsMatch "^status,on,status,off$"

Test-Case -Name "状态查询在途时切到 SDR → 判定直接丢弃" -Mode "slowstatus" -NextAfter 0.6 `
    -QuitAfter 10 -Extra @("--idle=yes") -List @("long.HDR.wav", $testLongVideo) `
    -Expect @("状态查询回调时文件已变化") -ExpectAbsent @("HDR 已开启") `
    -CallsMatch "^status$"

# 片尾防抖的 off 正在跑（慢速 1.5s），用户在这期间打开了下一部 HDR 片：
# 新片会因缓存/查询认为"系统已是 HDR"而放行，等 off 落地后必须回头补一次判断，
# 否则 HDR 片会在 SDR 下播完（stub 的 state.on 被删掉、脚本却以为无事可做）
Test-Case -Name "防抖关闭在途时打开新 HDR 片 → 关闭落地后会补开" -Mode "slowoff" -StopAfter 1 `
    -LoadAfter 3.6 -LoadFile (Join-Path $work "long.HDR.wav") -QuitAfter 12 -Extra @("--idle=yes") `
    -Media @("long.HDR.wav") `
    -Expect @("回调返回时文件已变化", "HDR 已开启") `
    -CallsMatch "off,.*on,off$"

Test-Case -Name "--pause 启动 → 脚本不解除用户的暂停" -Media @("movie.HDR.wav") -QuitAfter 6 `
    -Extra @("--pause") -ProbeAfter 5 `
    -Expect @("TESTPROBE pause=true") -ExpectAbsent @("TESTPROBE pause=false")

# ---------- 第三轮：物理握手跨文件 / 退出在途 on / 空闲暂停租约 ----------

# A 已开启 HDR、显示器还在黑屏里，用户切到下一部 HDR 片：
# 新片不能因为"系统状态已经是 HDR"就立刻开播，必须继承剩余的握手时间。
Test-Case -Name "握手等待期间切到下一部 HDR 片 → 继续等剩余时间" -SlowHandshake `
    -NextAfter 0.6 -ProbeAfter 1.0 -QuitAfter 8 `
    -List @("long.HDR.wav", "movie.HDR.wav") `
    -Expect @("TESTPROBE pause=true") -ExpectAbsent @("TESTPROBE pause=false")

# 上一部影片的 on 在切集之后才落地（副作用已发生、回调晚到）：
# 重判路径同样要沿用握手，不能立即解除暂停。
Test-Case -Name "上一部 on 在切集后才落地 → 重判也等握手" -SlowHandshake -Mode "slowexit" `
    -NextAfter 0.6 -ProbeAfter 2.0 -QuitAfter 8 `
    -List @("long.HDR.wav", "movie.HDR.wav") `
    -Expect @("TESTPROBE pause=true") -ExpectAbsent @("TESTPROBE pause=false")

# on 已经改了系统状态、回调还没回来时退出：不能因为 script_turned_on 还是 false 就漏关，
# 否则退出后系统会停在 HDR。
Test-Case -Name "on 在途时退出 → 同步补关，退出后不留 HDR" -Mode "slowexit" -QuitAfter 1 `
    -Media @("long.HDR.wav") `
    -Expect @("mpv 退出：关闭系统 HDR", "mpv 关闭：关闭系统 HDR") `
    -CallsMatch "^status,on,off,off$"

# 停止播放之后 on 才回调：空闲分支要归还脚本的暂停租约
# （pause 属性不会随文件卸载自动复位，只清标记会让下一个文件停在暂停上）
Test-Case -Name "停止播放后 on 才落地 → 空闲时归还暂停" -Mode "slowon" `
    -StopAfter 1 -ProbeAfter 2.5 -QuitAfter 6 -Extra @("--idle=yes") `
    -Media @("long.HDR.wav") `
    -Expect @("TESTPROBE pause=false") -ExpectAbsent @("TESTPROBE pause=true")

# ---------- 第四轮：查询有效性 / 退出结算 / 握手期间建立暂停 ----------

# 片尾防抖的 off 还没落地时打开 HDR 片：B 的查询读到的是切换前的 "on"，
# 之后 off 落地触发重判。重判不能复用那次旧读数，必须重查并重新开 HDR。
# 时序：A 的首次查询故意也慢（1.8s 才开 HDR）→ 3s 停止 → 5.5s 发 off（7.0s 才落地）
#       → 5.6s 打开 B（查询读到 on、7.15s 才返回）→ off 落地触发重判，复用旧读数就会让 B 在 SDR 下播。
Test-Case -Name "旧查询跨过 off 落地 → 重判必须重查" -Mode "slowexitstatus,slowoff" `
    -StopAfter 3 -LoadAfter 5.6 -LoadFile (Join-Path $work "movie.HDR.wav") -QuitAfter 14 `
    -Extra @("--idle=yes") -Media @("long.HDR.wav") `
    -Expect @("读数作废并重查", "HDR 已开启") -CallsMatch "off,.*on"

# 状态查询在途时 stop：查询回调因代次过期不能再"什么都不做"，空闲时要归还暂停
Test-Case -Name "状态查询在途时 stop → 空闲归还脚本暂停" -Mode "slowstatus" `
    -StopAfter 1 -ProbeAfter 2.5 -QuitAfter 6 -Extra @("--idle=yes") `
    -Media @("long.HDR.wav") `
    -Expect @("TESTPROBE pause=false") -ExpectAbsent @("TESTPROBE pause=true")

# on 比握手时长还慢时切到 SDR：定时器不能只看截止时间，命令未结算前不得放行
Test-Case -Name "on 慢于握手时长时切到 SDR → 命令落地前不放行" -Mode "slowon" `
    -NextAfter 0.6 -ProbeAfter 1.0 -QuitAfter 8 -Extra @("--idle=yes") `
    -List @("long.HDR.wav", $testLongVideo) `
    -Expect @("TESTPROBE pause=true") -ExpectAbsent @("TESTPROBE pause=false")

# 后台 off 的握手还没结束时打开 SDR：没有现成暂停，也要为它建立播放保护
Test-Case -Name "后台 off 握手期间打开 SDR → 建立暂停" -SlowHandshake -Mode "slowoff" `
    -StopAfter 1 -LoadAfter 5.4 -LoadFile $testLongVideo -ProbeAfter 6.0 -QuitAfter 10 `
    -Extra @("--idle=yes") -Media @("long.HDR.wav") `
    -Expect @("TESTPROBE pause=true") -ExpectAbsent @("TESTPROBE pause=false")

# on 非零退出、回读期间退出：在途计数要到"结算"才减，否则会漏掉退出清理
Test-Case -Name "on 失败回读期间退出 → 仍然补关" -Mode "fail,slowreread" -QuitAfter 1 `
    -Media @("long.HDR.wav") `
    -Expect @("mpv 退出：关闭系统 HDR", "mpv 关闭：关闭系统 HDR") `
    -CallsMatch "^status,on,status,off,off$"

# ---------- 第五轮：超时看门狗 / 握手期间提前保护 ----------

# 首次切换、命令一直不返回：finish() 永远不会来，没人检查上限就会永久暂停。
# 看门狗（下发后立即排的释放检查）必须在 10 秒宽限后按降级策略放行。
Test-Case -Name "首次切换命令卡死 → 超时后恢复播放" -Mode "hangon" `
    -Media @("long.HDR.wav") -ProbeAfter 12 -QuitAfter 13 `
    -Expect @("切换命令超时未返回", "TESTPROBE pause=false") `
    -ExpectAbsent @("TESTPROBE pause=true")

# 无 HDR 标签的文件在握手期间载入：从加载那一刻就该暂停，而不是等元数据检测（1.5s）完
Test-Case -Name "握手期间载入无标签文件 → 加载时就暂停" -SlowHandshake -Mode "slowoff" `
    -StopAfter 1 -LoadAfter 5.4 -LoadFile (Join-Path $work "plain.wav") -ProbeAfter 5.9 `
    -QuitAfter 10 -Extra @("--idle=yes") -Media @("long.HDR.wav") `
    -Expect @("TESTPROBE pause=true") -ExpectAbsent @("TESTPROBE pause=false")

# ---------- 汇总 ----------
Write-Host ""
$pass = @($script:results | Where-Object Pass).Count
$fail = @($script:results | Where-Object { -not $_.Pass }).Count

$i = 0
foreach ($r in $script:results) {
    $i++
    $tag = if ($r.Pass) { "PASS" } else { "FAIL" }
    $color = if ($r.Pass) { "Green" } else { "Red" }
    Write-Host ("[{0}/{1}] {2,-52} {3}" -f $i, $script:results.Count, $r.Name, $tag) -ForegroundColor $color
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
