# MPV Auto HDR Switcher for Windows

播放 HDR 影片时自动打开 Windows 的 HDR，播放 SDR 内容时自动切回 —— 不用再手动按 Win+Alt+B。

## 实际体验

| 场景 | HDR 状态 | 备注 |
| :--- | :--- | :--- |
| 打开 HDR 电影 | 开 | 从片头开始播，不漏首帧 |
| 连播 / 手动切集 | 保持开 | 不会有二次黑屏闪烁 |
| 拖动进度条 / 暂停 / 继续 | 不变 | 不会重复触发检测 |
| 切到 SDR 视频 | 关 | 黑屏一次，之后从片头续播 |
| 播完停在最后一帧 | 保持开 | 不急着切回 SDR，方便拖进度条回看 |
| 手动停止 / 关掉当前文件 | 延迟关 | 等 2.5 秒确认没有新任务 |
| 直接点 ✕ 退出 | 立即关 | 随播放器退出恢复 SDR |
| 系统本来就开着 HDR | 保持开 | 看完不会替你关掉 |
| 显示器不支持 HDR | 不动 | 不暂停、不调用、不等待 |
| 播放中自己改了 HDR | 按真实状态 | 之后的行为不会和你抢 |

## 安装

**1. 准备 `HDRCmd.exe`**

到 [HDRTray Releases](https://github.com/res2k/HDRTray/releases) 下载压缩包，解压出 `HDRCmd.exe`，
放到 `C:\Program Files\mpv\`（换别的位置也行，但要同步改脚本里的 `hdr_cmd_path`）。

**2. 放入脚本**

把 `auto-hdr.lua` 放进 mpv 的脚本目录：

* **便携版**：`mpv\portable_config\scripts\`
* **普通安装版**：`%APPDATA%\mpv\scripts\`

装完播一部 HDR 片即可验证，正常情况下不需要再做任何事。
如果没自动切换，再按 [DEVELOPER.md](DEVELOPER.md) 第 6 节的排错步骤查
（那里有 `HDRCmd.exe status` 等自检命令与日志开关）。

## 调参

只需要改 `auto-hdr.lua` 顶部的 `options`：

| 参数 | 默认 | 什么时候改 |
| :--- | :--- | :--- |
| `hdr_cmd_path` | `C:\\Program Files\\mpv\\HDRCmd.exe` | HDRCmd.exe 不在这个位置时。**Lua 里反斜杠必须写两个** |
| `handshake_delay_on` | `3.8` 秒 | **开** HDR 时等显示器黑屏结束的时间。画面亮了才开始播 → 调大；黑屏早结束了还在等 → 调小 |
| `handshake_delay_off` | `3.8` 秒 | **关** HDR 时的同一等待。开 HDR 的黑屏通常比关更长，所以两个值分开配 |

其余参数（判定逻辑、状态缓存、调试日志等）见 [DEVELOPER.md](DEVELOPER.md)。

## 注意

* **多显示器**：`HDRCmd.exe` 会连带切换**所有**支持 HDR 的屏幕，脚本不区分主副屏。
* **只关自己开的**：系统 HDR 如果是你手动开的，脚本看完不会替你关。
