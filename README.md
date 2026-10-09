# MPV Auto HDR Switcher for Windows

播放 HDR 影片时自动打开 Windows 的 HDR，播放 SDR 内容时自动切回 —— 不用再手动按 Win+Alt+B。

## 实际体验

| 场景 | 你会看到 |
| :--- | :--- |
| 打开 HDR 电影 | 从片头开始播，不漏首帧 |
| 连播 / 手动切集 | HDR 保持常亮，没有二次黑屏闪烁 |
| 拖动进度条 / 暂停 / 继续 | 不会重复触发切换 |
| 切到 SDR 视频 | 一次黑屏后切回 SDR，从片头续播 |
| 正常播完（停在最后一帧） | HDR 保持常亮，播完还能拖进度条回去回看，不会突然切回 SDR |
| 手动停止 / 关掉当前文件 | 等 2.5 秒确认没有新任务，再切回 SDR |
| 直接点 ✕ 退出 | 随播放器退出，立即恢复 SDR |
| 系统本来开着 HDR | 看完不会替你关掉 |
| 显示器不支持 HDR | 脚本自动跳过，没有任何停顿 |
| 播放中自己改了 HDR | 脚本以真实状态为准，不会和你抢 |

## 安装

**1. 准备 `HDRCmd.exe`**

到 [HDRTray Releases](https://github.com/res2k/HDRTray/releases) 下载压缩包，解压出 `HDRCmd.exe`，
放到 `C:\Program Files\mpv\`（换别的位置也行，但要同步改脚本里的 `hdr_cmd_path`）。

**2. 放入脚本**

把 `auto-hdr.lua` 放进 mpv 的脚本目录：

* **便携版**：`mpv\portable_config\scripts\`
* **普通安装版**：`%APPDATA%\mpv\scripts\`

**3. 确认能读到 HDR 状态**

PowerShell 里执行下面两条，第二条返回 `exit=1` 表示当前 HDR 是关的（开着则是 `exit=0`）：

```powershell
& 'C:\Program Files\mpv\HDRCmd.exe' status
& 'C:\Program Files\mpv\HDRCmd.exe' status -m x; "exit=$LASTEXITCODE"
```

## 调参

只需要改 `auto-hdr.lua` 顶部的 `options`，日常通常只动这两个：

| 参数 | 默认 | 什么时候改 |
| :--- | :--- | :--- |
| `hdr_cmd_path` | `C:\Program Files\mpv\HDRCmd.exe` | HDRCmd.exe 不在这个位置时（路径里的 `\` 写成 `\\`） |
| `handshake_delay_on` / `_off` | `3.8` / `3.8` | 黑屏结束了还在等 → 调小；画面亮了才开始播 → 调大 |

其余参数、判定逻辑与排错方法见 **[DEVELOPER.md](DEVELOPER.md)**。

## 注意

* **多显示器**：`HDRCmd.exe` 会连带切换**所有**支持 HDR 的屏幕，脚本不区分主副屏。
* **只关自己开的**：系统 HDR 如果是你手动开的，脚本看完不会替你关。
