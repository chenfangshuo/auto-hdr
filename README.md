# MPV Auto HDR Switcher for Windows

一个专为 Windows 11/10 打造的 MPV 终极自动 HDR 切换脚本。
彻底解决硬解元数据丢失、权限沙盒拦截、切集黑屏闪烁等痛点，提供丝滑完美的 HDR 观影体验。

## ✨ 核心特性

- **绕过 UAC 权限沙盒**：底层采用 PowerShell 异步代理执行，完美解决 `C:\Program Files\` 目录下直接调用子进程被系统拒绝的问题。
- **兼容原生硬件解码 (d3d11va)**：不仅检测常规的 `color-trc` 属性，针对 D3D11VA 硬解导致的元数据隔离，加入了 `gamma` 底层属性判定。
- **多重兜底机制**：如果遇到极度奇葩的视频封装导致 MPV 底层读取超时，脚本会自动降级采用**文件名关键字解析 (HDR/DV/DoVi/PQ)** 作为兜底。
- **防黑屏漏帧机制**：切入 HDR 时显示器通常需要 1.5~2 秒的硬件握手时间。本脚本会在发送开启指令的瞬间**自动暂停视频**，等屏幕点亮后再恢复播放，确保不漏掉一帧画面。
- **播放列表无缝切集**：引入了 `Debounce` (防抖倒计时) 机制。在播放列表连播或手动点击下一集 HDR 视频时，系统 HDR 状态保持常亮，**不会出现“关了立马又开”的二次黑屏闪烁**。
- **零干扰防打扰**：针对 `uosc` 等现代 UI 或鼠标拖动进度条的操作进行了状态记忆处理，进度条快进/快退绝对不会重复弹出 OSD 提示或重新检测。
- **主权隔离**：如果你在看电影前手动全局开启了 Windows HDR，脚本检测到后会自动放行，且在关闭视频时**不会越权关闭**你原有的 HDR 状态。

## 🛠️ 安装与依赖

1. 确保已在 Windows 10/11 环境下安装 MPV。
2. 下载控制系统 HDR 的外部依赖程序：[HDRCmd](https://github.com/bradleyf/hdr-cmd/releases) (将 `HDRCmd.exe` 解压到 `C:\Program Files\mpv\` 目录下，或你自定义的任意目录)。
3. 将本仓库的 `auto-hdr.lua` 放入 MPV 的脚本文件夹：
   `C:\Users\用户名\AppData\Roaming\mpv\scripts\` 或 便携版的 `portable_config\scripts\`。

## ⚙️ 用户配置

你可以用记事本打开 `auto-hdr.lua`，在最上方的 `options` 区域修改自定义配置：

```lua
local options = {
    -- HDRCmd.exe 的存放路径（注意：路径中的斜杠必须写双反斜杠 \\）
    hdr_cmd_path = "C:\\Program Files\\mpv\\HDRCmd.exe",
    
    -- 你的显示器切换 HDR 时的黑屏耗时（默认 1.5 秒）。如果你的显示器切得慢，可调大至 2.0
    handshake_delay = 1.5,
    
    -- 视频结束时延迟关闭 HDR 的时间（默认 2.5 秒）。用于保证切集时无缝衔接不闪屏
    turn_off_delay = 2.5,
}
