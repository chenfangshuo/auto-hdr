// 测试用的假 HDRCmd 替身。
//
// 为什么是 C# 而不是 .bat：脚本现在**直接调用 HDRCmd.exe**（mpv 在 Windows 上就是
// CreateProcessW），而 CreateProcess 只认真正的可执行映像，指向 .bat 会直接失败
// （返回 error_string == "init"）。所以替身必须编成 exe —— run-tests.ps1 在运行时
// 用 Add-Type / csc.exe 把它编出来，不往仓库里放二进制。
//
// 行为对齐真实 HDRCmd 的退出码语义：
//   status  有 mode-hang-status 时睡 60 秒（构造"首次查询一直不返回"）
//           有 mode-slow-status-once 时只有第 1 次 status 睡 1.5 秒
//           （构造"超时后新查询开始、旧结果迟到"）
//           有 mode-slow-status 时先睡 1.5 秒再读状态
//           （构造"状态查询还没回来用户就切集"的竞态）
//           有 mode-slow-exit-status 时**先读状态、再睡 1.5 秒**
//           （构造"读到的是切换前的值、回调却晚于切换落地"—— 真实进程在启动时读状态）
//           有 mode-slow-reread 且 on 已经失败过时睡 1.5 秒
//           （只拖慢失败之后的那次状态回读，构造"回读期间退出"）
//           有 mode-reread-error 时，第 2 次及以后 status 中的**第一次** → 3
//           （构造"失败后的回读也拿不到状态"；只消费一次，之后恢复正常）
//           有 mode-manual-on-after-status 时，读完状态后把 state.on 写出来
//           （模拟"查询读到 off 后、命令下发前，用户/其他来源把 HDR 打开了"）
//           有 mode-unsupported → 2（没有支持 HDR 的显示器）
//           有 state.on        → 0（HDR 已开）
//           否则              → 1（HDR 已关）
//   on      有 mode-hang-on 时睡 60 秒（构造"命令一直不返回"，验证超时兜底）
//           有 mode-on-effect-then-fail 时先写 state.on 再返回 3
//           （模拟"副作用已经发生、进程却异常结束"，且随后的回读不可用）
//           有 mode-slow-on 时先睡 1.5 秒（用来构造"命令还在途时切集/停止"的竞态）
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

    // 并发用例里多个子进程会同时写 calls.log：
    //   * FileShare.Read 让写者从 open 到 close 独占，避免两个 Append 定位到同一个
    //     文件尾互相覆盖（FileShare.ReadWrite 只防异常，不防覆盖）；
    //   * 抢不到就用共享冲突重试；全部失败必须留下错误标记，让用例硬失败，
    //     不能静默丢掉调用记录。
    private static void LogCall(string cmd)
    {
        for (int i = 0; i < 50; i++)
        {
            try
            {
                using (var fs = new FileStream(P("calls.log"), FileMode.Append, FileAccess.Write, FileShare.Read))
                using (var w = new StreamWriter(fs))
                {
                    w.Write("[" + cmd + "]\r\n");
                }
                return;
            }
            catch (IOException)
            {
                Thread.Sleep(10);
            }
        }
        try { File.WriteAllText(P("calls-log-error"), "calls.log append failed\r\n"); }
        catch { }
    }

    private static int StatusCount()
    {
        try
        {
            string path = P("status-count");
            int n = File.Exists(path) ? int.Parse(File.ReadAllText(path)) : 0;
            n++;
            File.WriteAllText(path, n.ToString());
            return n;
        }
        catch { return 1; }
    }

    private static int Main(string[] args)
    {
        string cmd = args.Length > 0 ? args[0].ToLowerInvariant() : "";
        LogCall(cmd);

        if (cmd == "status")
        {
            int statusNo = StatusCount();
            if (Has("mode-hang-status")) Thread.Sleep(60000);
            if (Has("mode-slow-status-once") && statusNo == 1) Thread.Sleep(1500);
            if (Has("mode-slow-status")) Thread.Sleep(1500);
            if (Has("mode-slow-reread") && Has("on-attempt")) Thread.Sleep(1500);
            bool unsupported = Has("mode-unsupported");
            bool on = Has("state.on");   // 先读状态，再慢慢退出
            // 模拟"查询读到 off 之后、命令下发之前，用户/其他来源把 HDR 打开了"
            if (Has("mode-manual-on-after-status")) File.WriteAllText(P("state.on"), "x");
            if (Has("mode-slow-exit-status")) Thread.Sleep(1500);
            // 失败后的第一次回读返回约定外代码（只消费一次；之后恢复正常，
            // 便于继续验证"切到 SDR 时会重新查询并关闭"）
            if (Has("mode-reread-error") && statusNo >= 2 && !Has("reread-error-used"))
            {
                File.WriteAllText(P("reread-error-used"), "x");
                return 3;
            }
            if (unsupported) return 2;
            return on ? 0 : 1;
        }
        if (cmd == "on")
        {
            File.WriteAllText(P("on-attempt"), "x");   // 供 mode-slow-reread 判断"失败回读"
            if (Has("mode-on-effect-then-fail"))
            {
                File.WriteAllText(P("state.on"), "x");  // 副作用已发生……
                return 3;                              // ……但进程异常结束
            }
            if (Has("mode-hang-on")) Thread.Sleep(60000);
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
