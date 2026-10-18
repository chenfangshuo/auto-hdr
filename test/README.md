# 测试

分三部分：**自动化逻辑自测**（用假 HDRCmd，不碰真实显示器，随时可跑）、
**真机自动化**（会真的切换显示器，但不需要按播放器按钮）和**真机 HDR 验收清单**（人工看观感）。

---

## 一、自动化逻辑自测

```powershell
# 在仓库根目录执行
.\test\run-tests.ps1

# 指定 mpv 位置 / 保留现场便于排查
.\test\run-tests.ps1 -MpvPath "D:\mpv\mpv.com" -KeepTemp
```

**原理**：`test\stub-hdrcmd.cs` 顶替真实的 `HDRCmd.exe` —— 它用 `state.on` 文件模拟"HDR 开着"，
把每次调用追加到 `calls.log`，还能用 `mode-fail` / `mode-unsupported` / `mode-off-fail` /
`mode-slow-on` / `mode-slow-status` / `mode-slow-off` / `mode-slow-exit-on` /
`mode-slow-exit-status` / `mode-slow-reread` 标记文件模拟异常、"命令/查询很慢"，以及
"副作用已经发生、进程还没退出"（`mode-slow-exit-on`、`mode-slow-exit-status`）和
"只拖慢失败之后的状态回读"（`mode-slow-reread`）。`Set-StubMode` 支持逗号分隔同时开多个模式。
脚本再把 `auto-hdr.lua` 复制一份补丁成：指向 stub、开 `debug`、握手缩到 0.3 秒，
然后用 mpv 真跑一遍事件流，最后断言脚本日志与 HDRCmd 的调用序列。

替身需要**运行时编译成 exe**（`run-tests.ps1` 用 `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`，
没有就退回 `Add-Type`）。原因是脚本现在直接调用 `HDRCmd.exe`，而 Windows 的 `CreateProcess`
只认可执行映像，`.bat` 会直接失败（`error_string == "init"`）。仓库里只存 `.cs` 源码，不放二进制。

脚本与 HDRCmd 之间的约定只有两条：**退出码**（0=开 / 1=关 / 2=不支持 / 非 0=失败）
和 stdout 里的 `HDR is on|off|unsupported`，所以 stub 可以完整替代真身。

覆盖的用例：

| 用例 | 断言重点 |
| :-- | :-- |
| HDR 文件名 → 预判开启 | 调用序列 `status,on`，且**不**进入元数据检测 |
| DoVi 文件名 → 预判开启 | 同上（杜比视界标签） |
| `HDRip` 文件名 | **不再**误判成 HDR（词边界生效），零外部调用 |
| `hdr_cmd_path` 写错 | 报「系统 HDR 状态查询失败」并整体旁路，**不静默当成"HDR 已开"** |
| 纯 SDR 视频（带真实 video-params） | 判定 `-> sdr`，且**零**外部调用（走快路径） |
| 音轨文件 | 元数据 `wait` 到超时 → 文件名兜底判 SDR |
| HDR → SDR 连播 | 调用恰好 `status,on,status,off`：中间不夹多余的一次关 |
| 命令失败（stub 返回非 0） | 报「HDR 开启失败」、回读真实状态，**不谎报成功** |
| 无 HDR 显示器（stub 返回 2） | 整体旁路：只有一次 status，没有任何 on/off |
| 播到结尾（`keep-open` 停在最后一帧） | **保持 HDR 不关**，方便拖进度条回看；退出时才关 |
| 手动 `stop`（文件被卸载） | 2.5s 防抖倒计时后关闭 |
| 播放中退出（✕ / `q`） | 立即同步关闭 |
| `off` 失败（stub 返回非 0） | 退出时**不谎报关闭**，保留标记留给 `shutdown` 重试（两次 off） |
| 停止播放打断在途的 `on` | 回调过期 → 按当前状态收尾，空闲时不留 HDR |
| 命令在途时切到 SDR | 旧结论**不套用**到新文件：日志应出现「HDR 已关闭（元数据）」 |
| **状态查询**在途时切到 SDR | 判定直接丢弃（`状态查询回调时文件已变化`），SDR 片不会被点亮 HDR |
| 防抖关闭在途时打开新 HDR 片 | 关闭落地后补一次判断：HDR 片不会在 SDR 下播（日志出现 `异步回调返回时文件已变化` 与 `HDR 已开启`） |
| `--pause` 启动 | 脚本**不解除**用户自己的暂停 |
| 握手等待期间切到下一部 HDR 片 | 新片**继承剩余握手时间**，不在黑屏未结束时开播（慢握手副本 2.0s） |
| 上一部 `on` 在切集后才落地 | 重判路径同样等握手（`mode-slow-exit-on` + 慢握手副本） |
| `on` 在途时退出 | 先 abort 在途请求、再同步关一次；`shutdown` 在 abort 之后补第二次：`status,on,off,off` |
| 停止播放后 `on` 才落地 | 空闲分支归还脚本的暂停租约（探针读到的 `pause=false`） |
| 查询读到 on、`off` 之后才返回 | 读数作废并**重查**，最终仍会开启 HDR（`off,.*on`） |
| 状态查询在途时 stop | 过期回调在空闲时归还脚本暂停（探针 `pause=false`） |
| `on` 比握手时长还慢时切到 SDR | 命令未结算前不放行（探针 `pause=true`） |
| 后台 `off` 握手期间打开 SDR | 没有现成暂停也会建立保护（探针 `pause=true`） |
| `on` 失败、回读期间退出 | 计数到结算才减：仍然补关 `status,on,status,off,off` |
| 首次切换时命令卡死（`mode-hang-on`） | 看门狗在下发时就启动：超时后按降级策略恢复播放，并打超时告警 |
| 握手期间载入无标签文件 | `start-file` 提前取得暂停（探针在载入 0.5s 后就读到 `pause=true`） |

全部通过时退出码为 0，有失败项则为失败数量，方便接到别的地方跑。

> 自动化测不到的两件事，需要看下面的真机清单：**真实黑屏时长**与**真实 HDR 观感**。

---

## 二、真机自动化（会切换显示器）

`test\real-machine.ps1` 把两个时序敏感的真机场景自动化：**用 mpv 的 IPC 命名管道代替按钮**
发送 `stop` / `loadfile`，用 `HDRCmd status` 的退出码判断系统 HDR 的真实状态，
再读 `[auto_hdr]` 日志确认走了哪条修复分支。不需要 uosc 的停止按钮。

```powershell
# 用 PowerShell 7（脚本是 UTF-8 无 BOM，Windows PowerShell 5.1 会把中文读坏）
pwsh -File .\test\real-machine.ps1              # 自动在仓库的上一级目录找 DV/SDR 片源，跑 A + B
pwsh -File .\test\real-machine.ps1 -Scenario A   # 只跑 A（不切系统 HDR）
pwsh -File .\test\real-machine.ps1 -HdrFile "D:\x.DV.mkv" -SdrFile "D:\y.mp4"
pwsh -File .\test\real-machine.ps1 -KeepTemp    # 保留日志与脚本副本
```

* **场景 A：状态查询在途时停止播放。** 为了在这台机器上稳定构造窗口，A 会把 `hdr_cmd_path`
  指向一个运行时编译的薄包装：`status` 先睡 1.5 秒再调用**真实** HDRCmd（`on`/`off` 不受影响）。
  断言：停播回到空闲后 `pause=false`，日志出现「状态查询回调时文件已变化」，且没有切换 HDR。
* **场景 B：后台关闭的黑屏握手期间打开 SDR。** 播放 HDR 片（脚本开 HDR）→ `stop` →
  等防抖关闭落地（显示器开始黑屏）→ 立刻 `loadfile` SDR 片。断言：新文件先被暂停
  （不会在黑屏里开播），握手结束后恢复播放且 `time-pos` 正常推进。
* B 会临时改变系统 HDR（必要时先关掉），结束时恢复测试前的状态；运行期间显示器会黑屏 1~2 次。
* 两个场景都用 `--no-config --vo=null --ao=null`，不弹播放窗口、不依赖个人配置。

> 场景 A 要求 HDR 片源文件名带 `HDR` / `DV` / `DoVi` 等标签（脚本才会走文件名预判路径）。

---

## 三、真机 HDR 验收清单

会真的切换显示器，建议按顺序过一遍：

1. **单部 HDR 片**：从片头开始播、不漏首帧；黑屏结束后画面就动。
   若黑屏早就结束而画面还在等 → 调小 `handshake_delay_on`；画面亮了才开始播 → 调大。
2. **走元数据路径**（文件名预判覆盖不到的那条）：把 HDR 片复制一份，文件名里删掉 `HDR` / `DV` / `DoVi` 字样再播。
   日志应出现 `元数据检测：gamma=pq ... -> hdr`。
3. **连播 3 集 HDR**：HDR 保持常亮，切集过程中不该有黑屏闪烁。
4. **HDR → SDR → HDR 混合列表**：切到 SDR 集只黑一次屏；再回到 HDR 集能重新点亮。
5. **播完保持 HDR**：单文件播完停在最后一帧时，HDR 应**保持**（方便拖进度条回去回看）；
   拖回去继续播也不该触发重新判定。此时关闭 mpv 才恢复 SDR。
6. **手动对抗**：播放中用 Win+Alt+B 自己开关 HDR，再切集 —— 脚本应以真实状态为准；
   片尾不要关掉你**手动**开的 HDR。
7. **退出**：播放中点 ✕ 或按 `q`，立即恢复 SDR；任务管理器里不应残留 `HDRCmd.exe`。
8. **拖动进度条 / 暂停继续**：日志里不应出现新的判定（路径去重生效）。
9. **切断依赖时的表现**：把 `options.hdr_cmd_path` 临时改成一个不存在的路径，打开 HDR 片 ——
   应看到 OSD「HDR: 无法获取系统 HDR 状态，已跳过」+ 日志「系统 HDR 状态查询失败」，
   画面正常播放（只是不切 HDR）。确认后把路径改回来。
10. **`--pause` 启动**：`mpv --pause 某HDR片.mkv` 应在切换完成后**保持暂停**，等你按空格。
11. **黑屏期间切下一集**：连播 HDR 时，在第一集的黑屏还没结束就手动切到下一集 ——
    新集必须等黑屏结束才开播，不能在剩余黑屏里先跑掉片头。
12. **开片立刻退出**：打开 HDR 片后 1 秒内点 ✕ —— 退出后系统应恢复 SDR（`on` 可能还在途，
    脚本会补一次关闭）。
13. **查询中停止**：打开 HDR 片后立刻按停止（趁状态查询还没回来）—— mpv 应处于**非暂停**状态，
    下次打开文件正常播放。
14. **恢复 SDR 的黑屏期间打开 SDR 片**：播放中手动 stop，等 HDR 开始切回 SDR 时马上打开一个
    SDR 文件 —— 新文件应等黑屏结束再开始播，不在黑屏里跑片头。

排错时把 `options.debug` 设为 `true`，看 `[auto_hdr]` 日志（字段含义见 [../DEVELOPER.md](../DEVELOPER.md) 第 6 节）。
