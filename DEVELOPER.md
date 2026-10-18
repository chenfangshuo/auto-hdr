# 开发文档 / 实现说明

面向想改脚本或在排查问题的人。用户向的说明见 [README.md](README.md)。

---

## 1. 运行流程

```
start-file          → 代次 +1；取消上一集遗留的关机倒计时（物理握手的剩余等待要沿用）
file-loaded         → 文件名命中 HDR 标签？→ 立刻判定（"文件名预判"，不等元数据）
playback-restart    → 否则进入元数据检测循环（0.1s 一次，最多 1.5s）
                       └─ 出结果 → do_hdr_switch() → 查系统真实状态 → 需要才切换
end-file            → 代次 +1；quit：同步关；其他（手动 stop 等）：2.5s 防抖倒计时后关
shutdown            → 兜底：仍标记为"本脚本开启"则同步关
```

**代次（`generation`）与"回调过期"**：切集/停止播放时，上一部影片发起的异步操作可能还在途，
它们的结果都属于上一部影片，不能拿来动当前文件的 HDR。`start-file` 与 `end-file` 都会把
`generation` 加一，两个窗口各守一次：

| 窗口 | 守卫位置 | 过期时的处理 |
| :--- | :--- | :--- |
| **状态查询**（`status -m x`，几十毫秒） | `do_hdr_switch()` 在调用 `query_hdr_state()` **之前**记下代次，回调第一行比对 | **直接丢弃**：这条路径还没下发过任何命令，不需要收尾；切集时新文件自己的事件流会判定。注意这里连暂停都不要碰（新文件可能正处在自己的握手里） |
| **切换命令**（`on`/`off`） | `do_switch_command()` 记下代次，回调末尾 `finish()` 比对（另加 `path` 是否为空） | `restage_current_file()`：**空闲就转入防抖关闭**（否则 HDR 会一直亮着），**有新文件就按新文件重跑一遍元数据检测** |
| **片尾防抖关闭**（片尾 2.5 秒后下发的 `off`） | `turn_off_hdr()` 记下代次，回调里比对 | 关闭真的落地时（`status == 0`）`restage_current_file()`：新文件在关闭落地前可能已按"系统还是 HDR"判断过（缓存命中 → 无缝衔接），不补一次，HDR 片就会在 SDR 下播完 |

三处都要有：

* 只在命令回调里比对不够 —— 查询期间切集的话，命令是在**新代次**下发出的，回调时
  `gen == generation` 成立，于是"上一部影片的结论被用在新影片上"，表现为 SDR 片被点亮 HDR
  （替身开 `mode-slow-status` 可稳定复现）。
* 只在查询回调里比对也不够 —— 命令已经在途时 `settle()` 仍会改内部状态。
* 片尾那条最容易漏 —— 它的窗口更窄（要在 2.5 秒防抖恰好触发的那几十毫秒里打开新文件），
  但后果是"HDR 片全程在 SDR 下播"，替身开 `mode-slow-off` 可稳定复现。

**物理握手是显示器状态，不是文件状态**：`handshake_until` 记录最近一次切换的握手截止时间，
它**跨文件有效**——`start-file` 不再丢弃"解除暂停"定时器，新文件继承剩余等待，
所有解除暂停的路径都经过 `release_pause()`，由它决定"现在放行"还是"等到截止时间"。

* `do_switch_command` / `turn_off_hdr` 在**下发命令时**就延长截止时间，命令回调落地后再刷新一次。
  只在回调里刷新会留下一个窗口：旧的解除暂停定时器可能比回调先到点，于是在新一次切换的黑屏里把画面放了。
* 定时器到点时会**再核对一次截止时间**：等待期间又发生了切换就按新时间重排，而不是直接解除。
* 两个入口都因此得到保护：① `on` 已确认、还在等待时切到下一部 HDR 片；② `on` 在切集之后才回调，
  `restage_current_file()` 重判时同样只能等到剩余时间。

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

兜底顺序：`hdr`/`sdr` → 直接定案；`unknown` 或等待超时 → 查文件名（`is_hdr_filename`）→ 都没有则判 SDR。
文件名标签（`hdr` / `hlg` / `dovi` / `dolby vision` / `.dv.` / `smpte2084`）**必须落在词边界上**，
匹配前会在两端各补一个 `.`：

| 文件名片段 | 判定 | 说明 |
| :--- | :--- | :--- |
| `.hdr.` / `.hdr10.` / `.hdr10+.` | HDR | 标签后跟的是分隔符或数字 |
| `.hdrip.` | 不是标签 | `HDRip` = HD Rip，**纯 SDR 片源**，`hdr` 后面跟的是字母 `i` |
| `.dvdrip.` | 不是标签 | `.dv.` 两侧都要求分隔符 |

> **三个易踩的坑**（都已在代码中修正）：
> * `video-params/gamma` **没有 `unknown` 这个取值**，`"auto"` 才是"无 TRC 标记"；
>   把 `"auto"` 当作"已就绪"会立刻误判成 SDR，并且永远走不到文件名兜底。
> * **`video-params/color-trc` 属性在 mpv 里不存在**（TRC 只有 `video-params/gamma` 一个字段），
>   不要照抄旧版本脚本里的这个写法。
> * **拿 `string.find(name, "hdr")` 裸匹配会把 `HDRip` 全带上**：文件名预判会立刻点亮 HDR，
>   而且它会抢先登记 `current_playing_path`，把后面的元数据检测挡掉，没有翻盘机会。

---

## 3. 系统 HDR 状态

`query_hdr_state(cb)` 执行 `HDRCmd.exe status -m x` 并读**退出码**：

| 退出码 | 含义 | 内部状态 |
| :--- | :--- | :--- |
| `0` | HDR 已开启 | `true` |
| `1` | HDR 已关闭 | `false` |
| `2` | 没有任何支持 HDR 的显示器 | `nil`（整体旁路） |
| 其它 | 退出码异常（含负值） | `nil`（整体旁路） |

* **`HDRCmd.exe` 是直接调用的**（`args = {路径, "status", "-m", "x"}`），不经 PowerShell：
  mpv 在 Windows 上就是 `CreateProcessW`，拿到的是**真实退出码**，路径里的空格/引号也不用自己转义。
  旧版经 `powershell -Command` 包装，一是每次多花约 0.7 秒冷启动（每次切换要调两次），
  二是 `powershell -Command` 会把任何非 0 退出码压成 1（要 `; exit $LASTEXITCODE` 才能透传），
  三是**路径写错时 PowerShell 自己起来了、退出码却是 0**，被读成"HDR 已开启"——
  于是 HDR 片不切 HDR、还弹"无缝衔接"，且下面那条"查询失败"日志永远不会出现。
  现在路径写错会直接得到 `error_string == "init"`，走"查询失败 → 整体旁路 + OSD 提示"。
* **切换决策一律实时查询，不读缓存**：单次查询约 22ms，没有省的必要。读缓存会让"用户在缓存有效期
  （1.5 秒）内手动开关 HDR"被误读成自己的操作 —— 例如把用户手动开的 HDR 认领成脚本开的，片尾再替人关掉。
* `cached_state` 只保留一个用途：`file-loaded` 判断"要不要在查询前先锁住画面"（启发式），
  受 `state_cache_ttl`（默认 1.5s）限制。同一时刻的并发查询仍由 `state_waiters` 合并成一次调用。
* 上游 `HDRCmd/subcommand/Status.cpp` 的 exitcode 模式（`-m x`）**只返回退出码、不输出任何文本**
  （`HDR is on/off/unsupported` 是默认 short 模式的输出），所以不存在"解析 stdout 兜底"这条路。
* `nil` 表示"不支持或查不到"：**不暂停、不调用、不等待**，只给一条 OSD 提示。
  否则在没有 HDR 能力的机器上，每部 HDR 片都会白等一次握手时长。
* 状态每次都重新查（而非启动时读一次），所以播放中手动 Win+Alt+B 后脚本行为仍然自洽；
  `script_turned_on` 只用于回答"这个 HDR 是不是我开的"，决定片尾能不能关。

---

## 4. 暂停所有权与定时器

三个定时器都有模块级句柄，入口处统一 **kill-then-set**：

| 变量 | 作用 |
| :--- | :--- |
| `unpause_timer` | 物理握手结束后解除暂停；截止时间在 `handshake_until`，切集不丢弃 |
| `check_timer` | 元数据轮询 |
| `turn_off_timer` | 片尾关机防抖倒计时；`start-file` 时无条件取消 |

`paused_by_script` 保证**只解除自己造成的暂停**，并且**跨文件保留**：
切集后新文件的决策路径（SDR 快路径、无缝衔接、切换完成）正是靠这个标记解除上一部遗留的暂停，
清掉它会让新文件永远停在暂停上。
`hold_pause()` 里还有一道守卫：**已经是暂停状态就不接管**，这样 `mpv --pause` 启动、
或用户在检测期间自己按的暂停，不会被 `release_pause*` 顺手解掉。

暂停租约的另外两条收尾：

* **空闲分支**（`restage_current_file` 发现 `path == ""`）先 `release_pause()` 再排防抖关闭 ——
  `pause` 属性会带到下一个文件，只清标记而不真正解除，下一个文件就会停在暂停上。
* **退出路径**用 `turn_on_inflight`（计数）+ `shutting_down` 兜住：
  `on` 可能已经改了系统状态、回调还没回来，此时 `script_turned_on` 仍是 `false`，
  只看它就会漏关。退出时先 `mp.abort_async_command` 取消在途 `on`，再同步下发 `off`
  （取消不等于撤销副作用，两者都要做）；`shutting_down` 让所有迟到的回调直接返回，
  不再起新的查询或切换。

需要切换时才 `hold_pause()`，切换前用 `rewind_if_needed()` 把已播掉的那零点几秒退回片头；
系统已处于目标状态时不做任何停顿（首次启动时缓存为空，会先暂停等查询结果，约 22ms）。

---

## 5. 参数

| 参数 | 默认 | 说明 |
| :--- | :--- | :--- |
| `hdr_cmd_path` | `C:\Program Files\mpv\HDRCmd.exe` | HDRCmd.exe 路径（Lua 里写 `\\`；直接交给 CreateProcess，不必管空格） |
| `handshake_delay_on` | `3.9` | 开启 HDR 后等待黑屏握手的时间（秒） |
| `handshake_delay_off` | `3.9` | 关闭 HDR 后等待黑屏握手的时间（秒）。开 HDR 的黑屏通常更长，故分开配置 |
| `turn_off_delay` | `2.5` | 播放结束后延迟关闭 HDR 的防抖窗口（秒） |
| `check_interval` | `0.1` | 元数据轮询间隔（秒） |
| `metadata_timeout` | `1.5` | 元数据最长等待时间（秒），超时后启用文件名兜底 |
| `state_cache_ttl` | `1.5` | 系统状态查询结果的缓存时长（秒） |
| `debug` | `false` | 调试日志开关 |

握手值的计时起点是 `HDRCmd on/off` 命令**落地之后**（下发时先占位，回调返回后再刷新），
所以实际停顿 ≈ `命令耗时 + handshake_delay`（直连 exe 后命令耗时只剩几十毫秒）。
截止时间**跨文件有效**：切集时只沿用剩余时间，不会重新等满。
默认 3.9 只是本机实测值：这块屏的黑屏约 3.8~3.9 秒，漏首帧就调大、黑屏早结束还在等就调小。

> **升级提示（3.8 → 3.9 的由来）**：旧版经 PowerShell 调用，`handshake_delay` 之外还有
> 两次约 0.7 秒的 PowerShell 冷启动（查状态 + 下命令），所以当时填 3.8 实际等了约 5.2 秒。
> 改成直连 exe 后净等待少了约 1.4 秒，**沿用旧值会漏掉片头几帧**（本机实测：3.8 漏、3.9 稳）。
> 从老版本升级上来时，把这两个值各加 0.1~0.3 秒重新试。

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
| `系统 HDR 状态查询失败：success=… error=…` | 子进程没起来（`error=init` = 可执行文件不存在），多半是 `hdr_cmd_path` 不对 |
| `系统 HDR 状态不可用，跳过本次切换（…）` | 上一条的后果：整体旁路，不暂停也不调用 |
| `元数据检测：gamma=… primaries=… sig-peak=… -> hdr/sdr/wait/unknown` | 判定依据 |
| `（预判路径）元数据快照：…` | 走文件名预判的文件，1 秒后补采一次元数据，用于确认片源真实参数 |
| `SDR 内容且系统 HDR 非本脚本开启，无需处理（…）` | 快路径：没有任何外部调用就结束 |
| `HDRCmd on/off 结束：success=… status=…` | 切换命令是否真的成功 |
| `HDR 开启失败 / HDR 关闭失败` | 命令没生效，内部状态**不会**被标成成功 |
| `关闭 HDR 未成功（status=…），保留状态标记以便重试` | `off` 退出码非 0，标记保留给退出路径再试 |
| `异步回调返回时文件已变化（切集或已停止），改为按当前状态收尾` | 回调过期，按当前文件（或空闲状态）重新决策（`restage_current_file`） |
| `状态查询回调时文件已变化，丢弃这次判定（…）` | 查询回调过期：这次判定属于上一部影片，直接丢弃、不切 HDR |
| `播放结束且无新视频：关闭系统 HDR` | 手动 stop / 被打断 / 回调过期后空闲，防抖倒计时走完并恢复 SDR |
| `mpv 退出 / mpv 关闭：关闭系统 HDR` | 退出路径的同步关闭（后者是 `shutdown` 兜底或重试）；`on` 还在途时同样会走这里，退出前补关 |

常见问题：

| 现象 | 原因 |
| :--- | :--- |
| OSD 提示"无法获取系统 HDR 状态" | `hdr_cmd_path` 错误，或 HDRCmd.exe 不在该路径（日志里有 `查询失败`） |
| HDR 片画面对了但没切 HDR，日志走"无缝衔接" | 系统 HDR 本来就是开的（可能是你手动开的） |
| 该切 SDR 却没切 | 系统 HDR 不是本脚本开的 —— 这是有意为之，不越权 |
| 文件误判 SDR | 看 `元数据检测` 行的 `gamma`；若是 `auto` 且文件名也没有 HDR 标签，属预期兜底结果 |
| 某片被点亮 HDR 但其实不是 HDR | 看日志走的是"文件名预判"（文件名里有 HDR 标签）还是"元数据"（`gamma=pq/hlg`）；`HDRip` / `DVDRip` 这类已按词边界排除 |
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
  标签已按词边界匹配，`HDRip` / `DVDRip` 这类不再误伤（见第 2 节）。
* **握手时长是固定值**：无法感知显示器真实的黑屏结束时刻，只能靠 `handshake_delay_*` 调。
* **播完不自动恢复 SDR（有意）**：见第 1 节。`keep-open` 下播到结尾只是停在最后一帧，
  文件仍被加载，脚本收不到 `end-file`，HDR 保持 —— 方便拖进度条回看。
  想恢复 SDR 就退出 mpv、或手动 stop、或播 SDR 内容。
* **`on`/`off` 的退出码只在异常时才复核**：退出码为 `0` 时直接采信
  （HDRCmd 约定：`0` = 结果与请求一致），非 `0` 才回读真实状态，避免每次都多跑一个进程。
  关闭路径（`turn_off_hdr`）则反过来：**必须**退出码为 `0` 才把"已关闭"记进内部状态，
  否则保留标记让 `shutdown` 再试一次。
* **多开 mpv 互不感知**：每个实例各自记录 `script_turned_on`。A 实例开着 HDR 时，
  B 实例退出仍可能把它关掉 —— 单进程内无法协调。
* **手动"关→开"无法识别**：所有权只有一个布尔值。脚本开启 HDR 后，如果你用 Win+Alt+B
  关掉再打开，脚本仍认为是自己开的，片尾/退出可能替你关掉。这是能力边界，不是多查一次能解决的。
  （反方向已经堵住：切换决策不再读缓存，所以"手动开 HDR 后 1.5 秒内打开视频"不会再被误认领。）
* **首次启动可能短暂预暂停**：缓存为空时 `file-loaded` 会先锁画面再查询（约 22ms）。
  异步查询无法同时保证"一次都不预暂停"和"绝不在需要等待时先播首帧"。
* **`--start=<2 秒` 会被退回 0**：`rewind_if_needed()` 只处理片头 2 秒内的情况，
  它是按"补回检测期间播掉的画面"设计的，代价是覆盖了你指定的起点。
* **播放中切换 HDR/SDR 视频轨道不会重判**：路径去重挡住了重复检测，
  同一个文件里混放两条轨道的场景不支持自动跟随。
* **命令没有全局串行化**：连续快速切集时，极端情况下可能有两次 `on` 同时在途。
  两者都是"开"，结果一致；真正需要串行的窗口只有几十毫秒，引入在途队列后一旦锁未释放
  就会永久卡死，风险大于收益。

---

## 8. 测试

逻辑层有自动化自测，用假 HDRCmd 跑完整事件流、**不碰真实显示器**：

```powershell
.\test\run-tests.ps1          # 22 个用例，约 3 分钟
```

替身是运行期编译出来的 `stub.exe`（仓库里只存 `stub-hdrcmd.cs` 源码）：脚本直接调用
`HDRCmd.exe`，而 `CreateProcess` 只认可执行映像，`.bat` 会直接失败。
用例清单、断言重点与真机验收清单见 [test/README.md](test/README.md)。
改完逻辑先跑它，比手动验证快得多。

---

## 9. 依赖的外部事实（核对来源）

* HDRCmd（[HDRTray, res2k](https://github.com/res2k/HDRTray)）：
  `HDRCmd/subcommand/Status.cpp`、`HDRCmd/HDRCmd.cpp`、`common/HDR.cpp`。
  short 模式 stdout 为单行 `HDR is on` / `HDR is off` / `HDR is unsupported`；
  `status -m x`（exitcode 模式）只返回退出码 `0`/`1`/`2`、**不输出 stdout**；
  `on`/`off` 成功 `0`、结果与请求不符 `1`、API 失败 `-1`；
  状态文本走 stdout、系统过旧的报错走 stderr。
* mpv（master 手册与 `player/command.c`、`player/playloop.c`、`video/csputils.c`）：
  `video-params/gamma` 取值含 `pq`/`hlg`，`auto` = 参数已知但 TRC 未指定；
  **不存在 `video-params/color-trc`**；`seek` 的 `absolute+exact` 需写成单个合并串；
  `playback-restart` 在 seek 后与文件加载后触发、**纯解除暂停不触发**；
  `end-file` 的 `reason` 取 `eof`/`stop`/`quit`/`error`/`redirect`/`unknown`，
  `shutdown` 在其后触发且可能多次；`subprocess` 是同步阻塞的，
  进程起不来**不抛 Lua 错误**而是返回 `error_string == "init"`（`MP_SUBPROCESS_EINIT`），
  `playback_only` 默认 `true`（当前播放项结束即杀进程）。
* `mp.command_native_async` 返回一个请求 id，可交给 `mp.abort_async_command`（0.30 起，client API 1.103）。
  **取消本身是异步的，也不撤销已经发生的副作用** —— 退出路径必须再同步下发一次 `off`。
* `pause` 默认**不随换文件复位**（要复位得显式 `--reset-on-next-file=pause`），
  所以"只清 `paused_by_script` 不解除暂停"会让下一个文件永远停在暂停上。
* mpv 的 Windows 子进程实现（`osdep/subprocess-win.c`）：
  `CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT`，
  **仅在当前进程没有控制台时才额外加 `CREATE_NO_WINDOW`**（所以直连 exe 不会闪黑框：
  `mpv.exe` 无控制台走前者，`mpv.com` 会继承同一个控制台）；
  `CreateProcessW` 失败时返回 `MP_SUBPROCESS_EINIT`，不区分具体错误码 ——
  所以**指向 `.bat` 或路径写错，表现都是 `error_string == "init"`**。
* 三条**本机实测**才确认、手册上不显眼的行为（写在这里免得以后踩回去）：
  1. `keep-open` 生效时文件在 EOF 处不卸载，**`end-file` 不触发**，只有 `eof-reached` 变 `true`
     （`keep-open=no` 时两者都来）。所以"播完"和"文件被卸载"不是同一件事，
     脚本刻意只依赖后者（见第 1 节的"播完不关"）。
  2. **PowerShell 包装会掩盖错误**（旧版写法，已弃用）：`& '不存在的.exe' status -m x` 报
     `CommandNotFoundException`，`$LASTEXITCODE` 保持 `$null`，于是附加的 `; exit $LASTEXITCODE`
     让进程**以退出码 0 结束** —— 脚本读成"HDR 已开启"，还弹"无缝衔接"；
     不加透传则是退出码 1，被读成"HDR 已关闭"。两种都是错的。
  3. 直连 exe 的耗时对比（同一台机器，同一块盘）：`powershell -NoProfile -WindowStyle Hidden -Command`
     包装约 **739ms/次**，直接调 `HDRCmd.exe status -m x` 约 **22ms/次**。
     每次切换要查一次状态 + 下一次命令，所以去包装后片头停顿少约 1.4 秒。
