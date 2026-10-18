<#
    真机自动化验收（会真的切换显示器 HDR）

    不依赖播放器的按钮：用 mpv 的 IPC 命名管道发送 stop / loadfile，
    用 HDRCmd 的退出码判断系统 HDR 的真实状态，用 [auto_hdr] 日志确认走了哪条修复分支。

    两个场景：
      A  状态查询在途时停止播放 → 查询回调过期后，脚本自己的暂停必须归还（空闲时 pause=false）
         为了在这台机器上稳定构造"查询还没回来"的窗口，A 会把 status 换成
         "先睡 1.5 秒再调用真实 HDRCmd" 的薄包装；on/off 仍然直接调用真实 HDRCmd。
      B  后台关闭 HDR（片尾防抖 off）落地后的黑屏握手期间打开 SDR 片
         → 新文件会被建立暂停，等握手结束才开播

    用法（在仓库根目录）：
        .\test\real-machine.ps1                        # 自动在仓库的上级目录找 DV/SDR 片源，跑 A + B
        .\test\real-machine.ps1 -Scenario A            # 只跑 A（不改系统 HDR 状态）
        .\test\real-machine.ps1 -HdrFile "D:\x.DV.mkv" -SdrFile "D:\y.mp4"
        .\test\real-machine.ps1 -KeepTemp              # 保留现场与日志

    注意：
      * B 会先把系统 HDR 切到关（必要时），结束后恢复测试前的状态；
      * A 只慢速化 status，播放中不会真的切 HDR；
      * 运行期间显示器会黑屏 1~2 次，属正常现象。
#>
param(
    [string]$HdrFile = "",
    [string]$SdrFile = "",
    [string]$MpvPath = "C:\Program Files\mpv\mpv.com",
    [string]$HdrCmdPath = "C:\Program Files\mpv\HDRCmd.exe",
    [ValidateSet("A", "B", "All")] [string]$Scenario = "All",
    [switch]$KeepTemp
)

$ErrorActionPreference = "Stop"
$script:failures = @()
$script:passes = @()

function Say([string]$Text, [string]$Color = "Gray") { Write-Host $Text -ForegroundColor $Color }
function Pass([string]$Name) { $script:passes += $Name; Write-Host ("  PASS  " + $Name) -ForegroundColor Green }
function Fail([string]$Name, [string]$Detail) {
    $script:failures += "$Name：$Detail"
    Write-Host ("  FAIL  " + $Name + "  —— " + $Detail) -ForegroundColor Red
}

# ---------- 片源与依赖 ----------
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # 仓库的上一级（放片源的地方）
if (-not $HdrFile) {
    $HdrFile = Get-ChildItem $projectRoot -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match '^\.(mkv|mp4|ts|m2ts)$' -and $_.Name -match 'dv|dovi|dolby|hdr' } |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $SdrFile) {
    $SdrFile = Get-ChildItem $projectRoot -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match '^\.(mkv|mp4|ts|m2ts)$' -and $_.Name -notmatch 'dv|dovi|dolby|hdr' } |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $HdrFile -or -not (Test-Path -LiteralPath $HdrFile)) { throw "找不到 HDR/DV 片源，用 -HdrFile 指定" }
if (-not $SdrFile -or -not (Test-Path -LiteralPath $SdrFile)) { throw "找不到 SDR 片源，用 -SdrFile 指定" }
if (-not (Test-Path $MpvPath))    { throw "找不到 mpv：$MpvPath" }
if (-not (Test-Path $HdrCmdPath)) { throw "找不到 HDRCmd：$HdrCmdPath" }

$hdrLeaf = Split-Path -Leaf $HdrFile
if ($Scenario -in @("A", "All") -and
    $hdrLeaf -notmatch '(?i)(hdr|dovi|dolby|smpte2084|(^|[^a-z])dv([^a-z]|$))') {
    throw "场景 A 需要 HDR 片源的文件名带 HDR/DV 标签（脚本才会走文件名预判）：$hdrLeaf"
}

Say "HDR 片源：$HdrFile"
Say "SDR 片源：$SdrFile"
Say "mpv：$MpvPath"
Say "HDRCmd：$HdrCmdPath"
Say ""

$work = Join-Path $env:TEMP "auto-hdr-real"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"

# ---------- HDRCmd 直连（真实状态） ----------
function Get-HdrState {
    & $HdrCmdPath status -m x *> $null
    return $LASTEXITCODE
}
function Set-HdrState([bool]$On) {
    $arg = if ($On) { "on" } else { "off" }
    & $HdrCmdPath $arg *> $null
    return $LASTEXITCODE
}
function Wait-HdrState([int]$Wanted, [double]$TimeoutSec, [string]$What) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Get-HdrState) -eq $Wanted) { return $true }
        Start-Sleep -Milliseconds 100
    }
    throw "等待超时：$What（期望退出码 $Wanted）"
}

# ---------- 慢速 status 包装（只给场景 A 用） ----------
function New-SlowStatusWrapper {
    $exe = Join-Path $work "hdr-cmd-slowstatus.exe"
    $cs = Join-Path $work "slowstatus.cs"
    $code = @"
using System;
using System.Diagnostics;
using System.Text;
using System.Threading;

internal static class SlowStatus
{
    private const string Real = @"$HdrCmdPath";

    private static int Main(string[] args)
    {
        if (args.Length > 0 && args[0].ToLowerInvariant() == "status") Thread.Sleep(1500);
        var psi = new ProcessStartInfo(Real);
        var sb = new StringBuilder();
        foreach (var a in args)
        {
            if (sb.Length > 0) sb.Append(' ');
            sb.Append('"').Append(a).Append('"');
        }
        psi.Arguments = sb.ToString();
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        var p = Process.Start(psi);
        p.WaitForExit();
        return p.ExitCode;
    }
}
"@
    [System.IO.File]::WriteAllText($cs, $code, $utf8)
    if (-not (Test-Path $csc)) { throw "找不到 csc.exe，无法生成慢速 status 包装" }
    & $csc /nologo /target:exe "/out:$exe" $cs | Out-Null
    if (-not (Test-Path $exe)) { throw "慢速 status 包装编译失败" }
    return $exe
}

# ---------- 生成测试用的 auto-hdr.lua（指向真实 HDRCmd、开 debug） ----------
function New-ScriptCopy([string]$DirName, [string]$HdrCmdForScript) {
    $dir = Join-Path $work $DirName
    New-Item -ItemType Directory -Path $dir | Out-Null
    $src = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) "auto-hdr.lua"), [System.Text.Encoding]::UTF8)
    $escaped = $HdrCmdForScript -replace '\\', '\\\\'
    $patched = $src.Replace('hdr_cmd_path = "C:\\Program Files\\mpv\\HDRCmd.exe"', 'hdr_cmd_path = "' + $escaped + '"')
    $patched = $patched.Replace('debug = false', 'debug = true')
    if ($patched -notmatch 'debug = true') { throw "脚本补丁没生效" }
    $path = Join-Path $dir "auto-hdr.lua"
    [System.IO.File]::WriteAllText($path, $patched, $utf8)
    return $path
}

# ---------- mpv + IPC ----------
function Start-TestMpv([string]$ScriptPath, [string]$Media) {
    $pipeName = "auto-hdr-real-$PID-$(Get-Random)"
    $outFile = Join-Path $work "mpv-out.txt"
    $errFile = Join-Path $work "mpv-err.txt"
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    $args = @(
        "--no-config", "--vo=null", "--ao=null", "--keep-open=yes", "--idle=yes",
        "--script=$ScriptPath",
        "--input-ipc-server=\\.\pipe\$pipeName",
        $Media
    )
    $argString = ($args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $proc = Start-Process -FilePath $MpvPath -ArgumentList $argString -NoNewWindow -PassThru `
                          -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $deadline = (Get-Date).AddSeconds(15)
        while ($true) {
            try { $pipe.Connect(500); break }
            catch {
                if ($proc.HasExited) { throw "mpv 启动后立即退出，见 $errFile" }
                if ((Get-Date) -gt $deadline) { throw "连接 mpv IPC 超时" }
                Start-Sleep -Milliseconds 200
            }
        }
        # NamedPipeClientStream 不支持 ReadTimeout，用 ReadLineAsync + Wait 控制超时
        $writer = New-Object System.IO.StreamWriter($pipe, $utf8)
        $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($pipe, [System.Text.Encoding]::UTF8)
    } catch {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
        throw
    }

    return [pscustomobject]@{
        Proc = $proc; Pipe = $pipe; Writer = $writer; Reader = $reader
        RequestId = 0; Out = $outFile; Err = $errFile; PipeName = $pipeName
    }
}

function Stop-TestMpv($Ctx) {
    try {
        if (-not $Ctx.Proc.HasExited) {
            Send-MpvCommand $Ctx @("quit")
            if (-not $Ctx.Proc.WaitForExit(8000)) { $Ctx.Proc.Kill() }
        }
    } catch { try { if (-not $Ctx.Proc.HasExited) { $Ctx.Proc.Kill() } } catch {} }
    try { $Ctx.Writer.Dispose() } catch {}
    try { $Ctx.Reader.Dispose() } catch {}
    try { $Ctx.Pipe.Dispose() } catch {}
}

function Send-MpvCommand($Ctx, [object[]]$Command) {
    $Ctx.RequestId++
    $payload = @{ command = $Command; request_id = $Ctx.RequestId } | ConvertTo-Json -Compress -Depth 6
    $Ctx.Writer.WriteLine($payload)
    $Ctx.Writer.Flush()
    while ($true) {
        $task = $Ctx.Reader.ReadLineAsync()
        if (-not $task.Wait(20000)) { throw "读取 mpv IPC 超时" }
        $line = $task.Result
        if ($null -eq $line) { throw "mpv IPC 已断开" }
        $obj = $line | ConvertFrom-Json
        if ($obj.request_id -eq $Ctx.RequestId) { return $obj }
        # 其它是事件（file-loaded / playback-restart 等），这里用不到
    }
}

function Get-MpvProp($Ctx, [string]$Name) {
    $r = Send-MpvCommand $Ctx @("get_property", $Name)
    if ($r.error -ne "success") { return $null }
    return $r.data
}

function Wait-Until([scriptblock]$Condition, [double]$TimeoutSec, [string]$What) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "等待超时：$What"
}

function Get-Log($Ctx) {
    $text = ""
    foreach ($f in @($Ctx.Out, $Ctx.Err)) {
        if (Test-Path $f) { $text += [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) + "`n" }
    }
    return $text
}
function Log-Has($Ctx, [string]$Needle) { return ((Get-Log $Ctx) -like "*$Needle*") }

# ==================== 场景 A ====================
function Invoke-ScenarioA {
    Say "`n=== A：状态查询在途时停止播放 ===" "Cyan"
    $wrapper = New-SlowStatusWrapper
    $scriptA = New-ScriptCopy "scenario-a" $wrapper
    $ctx = Start-TestMpv $scriptA $HdrFile
    try {
        # 脚本在 file-loaded 里先锁画面再查询；pause=true 说明查询已经发出（包装睡 1.5s）
        Wait-Until { (Get-MpvProp $ctx "pause") -eq $true } 90 "脚本预暂停 HDR 片"
        Pass "HDR 片被脚本先锁住画面（查询已发出）"

        Send-MpvCommand $ctx @("stop") | Out-Null
        Start-Sleep -Milliseconds 300
        # 用 idle-active 判断空闲：停播后 get_property path 可能返回 property unavailable
        Wait-Until { (Get-MpvProp $ctx "idle-active") -eq $true } 5 "停止后回到空闲"
        Pass "stop 后文件已卸载（空闲）"

        # 查询在 1.5s 后返回；过期分支应在空闲时归还暂停
        $released = $false
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline) {
            if ((Get-MpvProp $ctx "pause") -eq $false) { $released = $true; break }
            Start-Sleep -Milliseconds 100
        }
        if ($released) { Pass "过期查询返回后，空闲状态的暂停已归还（pause=false）" }
        else { Fail "过期查询返回后仍暂停" "5 秒内 pause 一直为 true" }
    } finally {
        Stop-TestMpv $ctx
    }

    # 日志在 mpv 退出后再读，避免输出缓冲导致误判
    if (Log-Has $ctx "状态查询回调时文件已变化") { Pass "日志确认走了过期分支" }
    else { Fail "日志缺少过期分支" "没有出现「状态查询回调时文件已变化」" }
    if (Log-Has $ctx "HDR 已开启") { Fail "不应切 HDR" "过期判定居然下发了 on" }
    else { Pass "没有因过期判定切换 HDR" }
}

# ==================== 场景 B ====================
function Invoke-ScenarioB {
    Say "`n=== B：后台关闭的黑屏握手期间打开 SDR ===" "Cyan"
    $initial = Get-HdrState
    Say ("测试前系统 HDR：退出码 " + $initial + "（0=开 / 1=关 / 2=不支持）")
    if ($initial -eq 2) { Fail "无 HDR 显示器" "HDRCmd status 返回 2，场景 B 无法进行"; return }

    $scriptB = New-ScriptCopy "scenario-b" $HdrCmdPath
    try {
        if ($initial -ne 1) {
            Set-HdrState $false | Out-Null
            Wait-HdrState 1 10 "把系统 HDR 关掉（测试前置）" | Out-Null
        }
        $ctx = Start-TestMpv $scriptB $HdrFile
        try {
            Wait-HdrState 0 30 "脚本把系统 HDR 打开" | Out-Null
            Pass "播放 HDR 片后系统 HDR 已打开"

            Send-MpvCommand $ctx @("stop") | Out-Null
            Wait-HdrState 1 15 "片尾防抖后系统 HDR 关闭" | Out-Null
            Pass "stop 后防抖关闭落地（显示器开始黑屏握手）"

            # 此时 handshake_until 还剩下约 3.9 秒
            Send-MpvCommand $ctx @("loadfile", $SdrFile) | Out-Null

            # 在手握手结束前采样：脚本应当为 SDR 文件建立暂停
            $sawPause = $false
            $deadline = (Get-Date).AddSeconds(2.5)
            while ((Get-Date) -lt $deadline) {
                if ((Get-MpvProp $ctx "pause") -eq $true) { $sawPause = $true; break }
                Start-Sleep -Milliseconds 200
            }
            if ($sawPause) { Pass "握手期间打开的 SDR 文件被暂停（不会在黑屏里开播）" }
            else { Fail "SDR 文件没有被建立暂停" "载入后 2.5 秒内 pause 一直为 false" }

            # 握手截止时间从 off 下发时算起（默认 3.9s），这里给足余量再要求恢复
            try {
                Wait-Until { (Get-MpvProp $ctx "pause") -eq $false } 8 "握手结束后恢复播放"
                Pass "握手结束后 SDR 文件恢复播放"
            } catch {
                Fail "握手结束后仍暂停" "8 秒内 pause 一直为 true"
            }

            $pos1 = Get-MpvProp $ctx "time-pos"
            Start-Sleep -Milliseconds 700
            $pos2 = Get-MpvProp $ctx "time-pos"
            if ($null -ne $pos1 -and $null -ne $pos2 -and $pos2 -gt $pos1) { Pass "SDR 文件在正常推进（time-pos 增长）" }
            else { Fail "SDR 文件没有推进" "time-pos：$pos1 -> $pos2" }

            $path = Get-MpvProp $ctx "path"
            if ($path -eq $SdrFile) { Pass "当前播放的确实是 SDR 片源" }
            else { Fail "当前文件不对" "path=$path" }
        } finally {
            Stop-TestMpv $ctx
        }

        # 日志在 mpv 退出后再读，避免输出缓冲导致误判
        if (Log-Has $ctx "SDR 内容且系统 HDR 非本脚本开启") { Pass "日志确认 SDR 走的是快路径" }
        else { Fail "日志缺少 SDR 快路径" "没有出现「SDR 内容且系统 HDR 非本脚本开启」" }
    } finally {
        if ($initial -ne 1) {
            Say "恢复测试前的系统 HDR 状态（打开）……"
            Set-HdrState $true | Out-Null
        }
    }
}

# ==================== 运行 ====================
try {
    if ($Scenario -in @("A", "All")) { Invoke-ScenarioA }
    if ($Scenario -in @("B", "All")) { Invoke-ScenarioB }
} finally {
    if ($KeepTemp) { Say "现场保留在：$work" "DarkGray" }
    else { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Say ""
$fail = $script:failures.Count
if ($fail -eq 0) {
    Say ("全部通过（" + $script:passes.Count + " 项）。") "Green"
    exit 0
}
Say ("失败 $fail 项，通过 " + $script:passes.Count + " 项：") "Red"
foreach ($f in $script:failures) { Say ("  - " + $f) "Red" }
exit $fail
