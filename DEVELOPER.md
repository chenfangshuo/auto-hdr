# 开发文档 / 实现说明

面向想改脚本或在排查问题的人。用户向的说明见 [README.md](README.md)。

---

## 1. 运行流程

```
start-file          → 取消上一集遗留的关机倒计时与"握手后解除暂停"
file-loaded         → 文件名命中 HDR 标签？→ 立刻判定（"文件名预判"，不等元数据）
playback-restart    → 否则进入元数据检测循环（0.1s 一次，最多 1.5s）
                       └─ 出结果 → do_hdr_switch() → 查系统真实状态 → 需要才切换
end-file            → quit：同步关；其他（手动 stop 等）：2.5s 防抖倒计时后关
shutdown            → 兜底：仍标记为"本脚本开启"则同步关
```

**关于"播完不关"（有意设计，别当 bug 修）**：mpv 的 `end-file` 只在**文件被卸载**时触发。
配了 `keep-open` 时，播到结尾只是暂停在最后一帧、文件仍被加载，所以 `end-file` **不会来**，
HDR 就保持开启 —— 这正是想要的：播完往往还要拖进度条回去回看，不该被切回 SDR。
于是实际会关闭 HDR 的时机只有三个：**退出 mpv**、**手动 stop / 关掉文件**（文件被卸载，走 2.5s 防抖）、
**切到 SDR 内容**。不要为了"播完就关"去监听 `eof-reached`，那会破坏回看体验。

其它几个事件语义（都已实测确认）：

* `end-file` 的 `reason`：自然播完 `eof`、被 `loadfile`/`playlist-next` 打断 `stop`、关窗口或 `q` 为 `quit`。
* `playback-restart` 在**每次 seek 之后**与文件加载后触发，**单纯解除暂停不触发**
  —— 这正是脚本自己的 `pause=false` 不会引发死循环、而路径去重必须存在的原因。
* 只有在真的有文件在播时才有 `end-file`；空闲状态下退出只有 `shutdown`。

**路径去重**：`playback-restart` 在每次 seek 后也会触发，所以用 `current_playing_path`
挡住重复检测；命中文件名预判的文件会被抢先登记路径，从而跳过元数据检测。

**快路径**：SDR 内容 + `script_turned_on == false` 时无事可做，直接放行，
连一次 PowerShell 查询都省掉。

---

## 2. HDR 判定

以 `video-params/gamma`（传输特性）为主，`classify_video()` 返回四态：

| `gamma` 取值 | 含义 | 处理 |
| :--- | :--- | :--- |
| `""` | `video-params` 节点还没就绪（首帧未解出） | `wait`：继续轮询，超时后走兜底 |
| `pq` / `hlg` | 正常 HDR | `hdr` |
| `auto` | 参数已知但**传输特性未标记**（不再会变好） | 先看 `primaries == bt.2020` 或 `sig-peak > 1`；仍不确定 → `unknown` |
| 其他（`bt.1886`、`srgb` …） | 正常 SDR | `sdr` |

兜底顺序：`hdr`/`sdr` → 直接定案；`unknown` 或等待超时 → 查文件名（`is_hdr_filename`，
匹配 `hdr` / `dovi` / `dolby vision` / `.dv.` / `smpte2084` / `hlg`）→ 都没有则判 SDR。

> **两个易踩的坑**（都已在代码中修正）：
> * `video-params/gamma` **没有 `unknown` 这个取值**，`"auto"` 才是"无 TRC 标记"；
>   把 `"auto"` 当作"已就绪"会立刻误判成 SDR，并且永远走不到文件名兜底。
> * **`video-params/color-trc` 属性在 mpv 里不存在**（TRC 只有 `video-params/gamma` 一个字段），
>   不要照抄旧版本脚本里的这个写法。

---

## 3. 系统 HDR 状态

`query_hdr_state(cb)` 执行 `HDRCmd.exe status -m x` 并读**退出码**：

| 退出码 | 含义 | 内部状态 |
| :--- | :--- | :--- |
| `0` | HDR 已开启 | `true` |
| `1` | HDR 已关闭 | `false` |
| `2` | 没有任何支持 HDR 的显示器 | `nil`（整体旁路） |
| 其他/负值 | 退出码异常 | 回退解析 stdout 的 `hdr is on` / `hdr is off`，都匹配不上则为 `nil` |

* **Windows 上正常退出也可能得到负 status**（win32 UINT/int 伪影），所以不做"负值即失败"的一刀切。
* **必须给 status 调用加上 `; exit $LASTEXITCODE`**：`powershell -Command` 会把**任何非 0 退出码压成 1**，
  不加的话 `2`（没有支持 HDR 的显示器）会被误读成 `1`（HDR 已关闭），
  "不支持就整体旁路"这条逻辑会失效。实测：0→0、1→1、2→1（不加）、2→2（加了）。
  `on`/`off` 不需要透传 —— 那里只关心"是不是 0"。
* 结果缓存 `state_cache_ttl`（默认 1.5s），同一时刻的并发请求会合并成一次调用。
* `nil` 表示"不支持或查不到"：**不暂停、不调用、不等待**，只给一条 OSD 提示。
  否则在没有 HDR 能力的机器上，每部 HDR 片都会白等一次握手时长。
* 状态每次都重新查（而非启动时读一次），所以播放中手动 Win+Alt+B 后脚本行为仍然自洽；
  `script_turned_on` 只用于回答"这个 HDR 是不是我开的"，决定片尾能不能关。

---

## 4. 暂停所有权与定时器

三个定时器都有模块级句柄，入口处统一 **kill-then-set**：

| 变量 | 作用 |
| :--- | :--- |
| `unpause_timer` | 握手结束后解除暂停；切集时会被 `drop_pending_unpause()` 丢弃 |
| `check_timer` | 元数据轮询 |
| `turn_off_timer` | 片尾关机防抖倒计时；`start-file` 时无条件取消 |

`paused_by_script` 保证**只解除自己造成的暂停**：用户手动暂停不会被脚本的定时器顶掉，
上一部片子的握手也不会解除新文件的暂停（否则新文件会在显示器黑屏期间开播，丢首帧）。

需要切换时才 `hold_pause()`，切换前用 `rewind_if_needed()` 把已播掉的那零点几秒退回片头；
系统已处于目标状态时不做任何停顿。

---

## 5. 参数

| 参数 | 默认 | 说明 |
| :--- | :--- | :--- |
| `hdr_cmd_path` | `C:\Program Files\mpv\HDRCmd.exe` | HDRCmd.exe 路径（Lua 里写 `\\`） |
| `handshake_delay_on` | `3.8` | 开启 HDR 后等待黑屏握手的时间（秒） |
| `handshake_delay_off` | `3.8` | 关闭 HDR 后等待黑屏握手的时间（秒）。开 HDR 的黑屏通常更长，故分开配置 |
| `turn_off_delay` | `2.5` | 播放结束后延迟关闭 HDR 的防抖窗口（秒） |
| `check_interval` | `0.1` | 元数据轮询间隔（秒） |
| `metadata_timeout` | `1.5` | 元数据最长等待时间（秒），超时后启用文件名兜底 |
| `state_cache_ttl` | `1.5` | 系统状态查询结果的缓存时长（秒） |
| `debug` | `false` | 调试日志开关 |

握手的计时起点是 `HDRCmd on/off` 命令**回调返回之后**，所以实际停顿 ≈
`PowerShell 启动开销 + handshake_delay`。若屏幕上黑屏已经结束而画面还没动，说明该值偏大。

---

## 6. 排错

**第一步先自检依赖**（PowerShell 里执行；第二条返回 `exit=1` 表示当前 HDR 是关的，开着则是 `exit=0`）：

```powershell
& 'C:\Program Files\mpv\HDRCmd.exe' status
& 'C:\Program Files\mpv\HDRCmd.exe' status -m x; "exit=$LASTEXITCODE"
```

两条都正常再往下看日志；报"找不到文件/命令"就是 `hdr_cmd_path` 配错了。

然后**把 `debug` 改成 `true`**，看 mpv 日志（前缀 `[auto_hdr]`）：

* **终端版**：`mpv.com` 直接可见；`mpv.exe` 按 `~` 打开控制台。
* info 级消息默认就会显示，通常不需要额外加 `--msg-level`。

日志会给出决策链的每一步：

| 日志 | 含义 |
| :--- | :--- |
| `系统 HDR 状态：true/false（退出码 N）` | 查到的真实状态及 HDRCmd 返回码 |
| `HDR 状态命中缓存：…` | 该次判断走了缓存，没有真的调 PowerShell |
| `系统 HDR 状态查询失败：success=… error=…` | 子进程没起来，多半是 `hdr_cmd_path` 不对 |
| `元数据检测：gamma=… primaries=… sig-peak=… -> hdr/sdr/wait/unknown` | 判定依据 |
| `（预判路径）元数据快照：…` | 走文件名预判的文件，1 秒后补采一次元数据，用于确认片源真实参数 |
| `SDR 内容且系统 HDR 非本脚本开启，无需处理（…）` | 快路径：没有任何外部调用就结束 |
| `HDRCmd on/off 结束：success=… status=…` | 切换命令是否真的成功 |
| `HDR 开启失败 / HDR 关闭失败` | 命令没生效，内部状态**不会**被标成成功 |
| `播放结束且无新视频：关闭系统 HDR` | 手动 stop / 被打断后，防抖倒计时走完并恢复 SDR |
| `mpv 退出：关闭系统 HDR` | 退出路径的同步关闭 |

常见问题：

| 现象 | 原因 |
| :--- | :--- |
| OSD 提示"无法获取系统 HDR 状态" | `hdr_cmd_path` 错误，或 HDRCmd.exe 不在该路径 |
| HDR 片画面对了但没切 HDR，日志走"无缝衔接" | 系统 HDR 本来就是开的（可能是你手动开的） |
| 该切 SDR 却没切 | 系统 HDR 不是本脚本开的 —— 这是有意为之，不越权 |
| 文件误判 SDR | 看 `元数据检测` 行的 `gamma`；若是 `auto` 且文件名也没有 HDR 标签，属预期兜底结果 |
| 片头停顿偏长 | 调小 `handshake_delay_on`；或看 `元数据检测` 是否一直在 `wait`（元数据出得慢） |

> 注意：`mp.msg.*` **不做 printf 替换**（多参数是空格拼接），加日志时必须自己
> `string.format`，否则会打出字面的 `%s`。

---

## 7. 已知限制与取舍

* **多显示器**：HDRCmd 的状态是聚合值（任一支持的显示器开启即为 `on`），
  且 `on`/`off` 作用于所有支持的显示器。要限定单屏需 HDRCmd v0.5.93+ 的
  `-d` / `select`，本脚本未使用。
* **文件名预判优先于元数据**：命中 HDR 标签的文件会直接按 HDR 处理，
  不再核对元数据（换来的是不等首帧、判定零延迟）；代价是文件名错标的 SDR 会被点亮 HDR。
* **握手时长是固定值**：无法感知显示器真实的黑屏结束时刻，只能靠 `handshake_delay_*` 调。
* **播完不自动恢复 SDR（有意）**：见第 1 节。`keep-open` 下播到结尾只是停在最后一帧，
  文件仍被加载，脚本收不到 `end-file`，HDR 保持 —— 方便拖进度条回看。
  想恢复 SDR 就退出 mpv、或手动 stop、或播 SDR 内容。
* **`on`/`off` 的退出码只在异常时才复核**：退出码为 `0` 时直接采信
  （HDRCmd 约定：`0` = 结果与请求一致），非 `0` 才回读真实状态，避免每次都多跑一个进程。

---

## 8. 测试

逻辑层有自动化自测，用假 HDRCmd 跑完整事件流、**不碰真实显示器**：

```powershell
.\test\run-tests.ps1          # 9 个用例，约 1 分钟
```

用例清单、断言重点与真机验收清单见 [test/README.md](test/README.md)。
改完逻辑先跑它，比手动验证快得多。

---

## 9. 依赖的外部事实（核对来源）

* HDRCmd（[HDRTray, res2k](https://github.com/res2k/HDRTray)）：
  `HDRCmd/subcommand/Status.cpp`、`HDRCmd/HDRCmd.cpp`、`common/HDR.cpp`。
  short 模式 stdout 为单行 `HDR is on` / `HDR is off` / `HDR is unsupported`；
  `status -m x` 退出码 `0`/`1`/`2`；`on`/`off` 成功 `0`、结果与请求不符 `1`、API 失败 `-1`；
  状态文本走 stdout、系统过旧的报错走 stderr。
* mpv（master 手册与 `player/command.c`、`player/playloop.c`、`video/csputils.c`）：
  `video-params/gamma` 取值含 `pq`/`hlg`，`auto` = 参数已知但 TRC 未指定；
  **不存在 `video-params/color-trc`**；`seek` 的 `absolute+exact` 需写成单个合并串；
  `playback-restart` 在 seek 后与文件加载后触发、**纯解除暂停不触发**；
  `end-file` 的 `reason` 取 `eof`/`stop`/`quit`/`error`/`redirect`/`unknown`，
  `shutdown` 在其后触发且可能多次；`subprocess` 是同步阻塞的，
  进程起不来**不抛 Lua 错误**而是返回 `error_string == "init"`，
  `playback_only` 默认 `true`（当前播放项结束即杀进程）。
* 两条**本机实测**才确认、手册上不显眼的行为（写在这里免得以后踩回去）：
  1. `keep-open` 生效时文件在 EOF 处不卸载，**`end-file` 不触发**，只有 `eof-reached` 变 `true`
     （`keep-open=no` 时两者都来）。所以"播完"和"文件被卸载"不是同一件事，
     脚本刻意只依赖后者（见第 1 节的"播完不关"）。
  2. `powershell -Command "& 'x.exe' ..."` **把任何非 0 退出码压成 1**，
     需要 `; exit $LASTEXITCODE` 才能拿到原始码（0/1/2）。
