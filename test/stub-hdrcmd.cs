// 测试用的假 HDRCmd 替身。
//
// 为什么是 C# 而不是 .bat：脚本现在**直接调用 HDRCmd.exe**（mpv 在 Windows 上就是
// CreateProcessW），而 CreateProcess 只认真正的可执行映像，指向 .bat 会直接失败
// （返回 error_string == "init"）。所以替身必须编成 exe —— run-tests.ps1 在运行时
// 用 Add-Type / csc.exe 把它编出来，不往仓库里放二进制。
//
// 行为对齐真实 HDRCmd 的退出码语义：
//   status  有 mode-slow-status 时先睡 1.5 秒（构造"状态查询还没回来用户就切集"的竞态）
//           有 mode-unsupported → 2（没有支持 HDR 的显示器）
//           有 state.on        → 0（HDR 已开）
//           否则              → 1（HDR 已关）
//   on      有 mode-slow-on 时先睡 1.5 秒（用来构造"命令还在途时切集/停止"的竞态）
//           有 mode-slow-exit-on 时**先写 state.on 再睡 1.5 秒**（模拟"副作用已经发生、
//                                 回调还没到达"的退出窗口 —— 与实际 HDRCmd 先改状态再退出一致）
//           有 mode-fail      → 3（模拟切换失败）
//           否则写 state.on 并返回 0
//   off     有 mode-slow-off 时先睡 1.5 秒（构造"关闭还没落地新片就开播"的竞态）
//           有 mode-off-fail  → 1，且不删 state.on（模拟"关不掉"）
//           否则删 state.on 并返回 0
//
// 每次调用都往 calls.log 追加一行 [子命令]，便于断言调用序列。
using System;
using System.IO;
using System.Threading;

internal static class StubHdrCmd
{
    private static string Dir = AppDomain.CurrentDomain.BaseDirectory;

    private static string P(string name) { return Path.Combine(Dir, name); }
    private static bool Has(string name) { return File.Exists(P(name)); }

    private static int Main(string[] args)
    {
        string cmd = args.Length > 0 ? args[0].ToLowerInvariant() : "";
        File.AppendAllText(P("calls.log"), "[" + cmd + "]\r\n");

        if (cmd == "status")
        {
            if (Has("mode-slow-status")) Thread.Sleep(1500);
            if (Has("mode-unsupported")) return 2;
            return Has("state.on") ? 0 : 1;
        }
        if (cmd == "on")
        {
            if (Has("mode-slow-exit-on"))
            {
                File.WriteAllText(P("state.on"), "x");
                Thread.Sleep(1500);
                return 0;
            }
            if (Has("mode-slow-on")) Thread.Sleep(1500);
            if (Has("mode-fail")) return 3;
            File.WriteAllText(P("state.on"), "x");
            return 0;
        }
        if (cmd == "off")
        {
            if (Has("mode-slow-off")) Thread.Sleep(1500);
            if (Has("mode-off-fail")) return 1;
            if (Has("state.on")) File.Delete(P("state.on"));
            return 0;
        }
        return 0;
    }
}
