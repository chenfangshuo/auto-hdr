--[[
    MPV Auto HDR Switcher for Windows
    自动检测 HDR 视频并无缝切换 Windows 系统的 HDR 状态。
]]

-- ==================== 用户配置区域 ====================
local options = {
    -- HDRCmd.exe 的绝对路径（注意：Lua 中需使用双反斜杠 \\）
    hdr_cmd_path = "C:\\Program Files\\mpv\\HDRCmd.exe",
    
    -- 防漏帧延迟：显示器切换 HDR 时的黑屏物理握手时间（秒）。
    -- 脚本会在此期间暂停视频，确保画面点亮时从第一帧开始播放。
    handshake_delay = 2.5,
    
    -- 延迟关闭时间：播放结束时，延迟关闭 HDR 的时间（秒）。
    -- 作用：在播放列表自动播下一集，或手动切集时，防止 HDR 关了又开导致屏幕闪烁。
    turn_off_delay = 2.5,
    
    -- 底层数据检测超时阈值。
    -- 每 0.2 秒检测一次，25 次即 5 秒。超时未读到元数据将启用“文件名兜底识别”。
    max_check_attempts = 25
}
-- ======================================================

local script_turned_on = false 
local check_timer = nil
local turn_off_timer = nil
local current_playing_path = ""  -- 记录当前播放路径，防止拖动进度条时重复触发检测

-- 执行 PowerShell 代理命令（获取当前 HDR 状态，绕过 MPV 直接调用 exe 的权限沙盒）
function get_system_hdr_status()
    local res = mp.command_native({
        name = "subprocess",
        args = {"powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", "& '" .. options.hdr_cmd_path .. "' status"},
        capture_stdout = true,
        capture_stderr = true
    })
    local out = res.stdout or ""
    local lower_out = string.lower(out)
    return string.find(lower_out, "on") or string.find(lower_out, "1")
end

-- 核心切换逻辑
function do_hdr_switch(is_movie_hdr, trigger_reason)
    local is_sys_hdr = get_system_hdr_status()
    if is_sys_hdr == nil then is_sys_hdr = false end

    if is_movie_hdr then
        if not is_sys_hdr then
            mp.msg.info("检测到 HDR (" .. trigger_reason .. ")，正在开启...")
            
            -- 1. 立即暂停，防止漏掉视频开头的画面
            mp.set_property_bool("pause", true)
            mp.osd_message("HDR: 正在准备开启...", 2)

            -- 2. 异步执行开启命令，避免阻塞 MPV 导致界面假死
            mp.command_native_async({
                name = "subprocess",
                args = {"powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", "& '" .. options.hdr_cmd_path .. "' on"}
            }, function()
                script_turned_on = true
                mp.osd_message("HDR: 自动开启 (" .. trigger_reason .. ")", 2)
                
                -- 3. 等待显示器硬件握手完成后，自动恢复播放
                mp.add_timeout(options.handshake_delay, function()
                    mp.set_property_bool("pause", false)
                end)
            end)
        else
            -- 若检测到 HDR 且系统已在 HDR 状态（如无缝切集），直接放行
            mp.msg.info("检测到 HDR，且系统已在 HDR 状态，无缝播放。")
            mp.osd_message("HDR: 无缝衔接 (" .. trigger_reason .. ")", 2)
        end
    else
        -- 播放 SDR 视频时，若系统 HDR 是由本脚本开启的，则将其关闭
        if is_sys_hdr and script_turned_on then
            mp.msg.info("检测到 SDR 视频，正在关闭系统 HDR...")
            mp.osd_message("HDR: 自动恢复 SDR", 3)
            mp.command_native_async({
                name = "subprocess",
                args = {"powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", "& '" .. options.hdr_cmd_path .. "' off"}
            }, function()
                script_turned_on = false
            end)
        end
    end
end

-- 视频加载时的状态检测逻辑
function start_checking()
    local path = mp.get_property("path", "")
    
    -- 【防打扰机制】：防止拖动进度条或解除暂停（触发 playback-restart）时重复检测
    if path == current_playing_path and path ~= "" then
        return
    end
    current_playing_path = path

    -- 加载新视频时，立刻取消上一集的“关机倒计时”（实现无缝切集）
    if turn_off_timer then 
        turn_off_timer:kill()
        turn_off_timer = nil
    end

    local attempts = 0
    if check_timer then check_timer:kill() end
    
    -- 循环检测底层色彩空间数据（应对硬解初始化的延迟）
    check_timer = mp.add_periodic_timer(0.2, function()
        attempts = attempts + 1
        
        local gamma = mp.get_property("video-params/gamma", "")
        local color_trc = mp.get_property("video-params/color-trc", "")
        local filename = mp.get_property("filename", "")
        
        local is_hdr = false
        local reason = ""
        
        -- 优先判断 d3d11va 原生硬解映射的 gamma 属性
        if gamma == "pq" or gamma == "hlg" then
            is_hdr = true
            reason = "Gamma"
        -- 其次判断软解或其他硬解路线的 color-trc 属性
        elseif color_trc == "smpte2084" or color_trc == "pq" or color_trc == "hlg" then
            is_hdr = true
            reason = "TRC"
        end
        
        -- 如果成功读取到了底层数据，立即执行切换并终止检测
        if (gamma ~= "" and gamma ~= "unknown") or (color_trc ~= "" and color_trc ~= "unknown") then
            check_timer:kill()
            do_hdr_switch(is_hdr, reason)
            
        -- 如果超时未读到（例如特殊封装导致元数据丢失），启动文件名兜底判定
        elseif attempts > options.max_check_attempts then
            check_timer:kill()
            local lower_name = string.lower(filename)
            if string.find(lower_name, "hdr") or string.find(lower_name, "dovi") or string.find(lower_name, "dv") or string.find(lower_name, "pq") then
                do_hdr_switch(true, "文件名")
            else
                do_hdr_switch(false, "SDR")
            end
        end
    end)
end

mp.register_event("playback-restart", start_checking)

-- 视频结束/退出时的清理逻辑
mp.register_event("end-file", function(e)
    -- 清空当前播放记录，确保下次重新播该视频能正常检测
    current_playing_path = ""
    
    if check_timer then check_timer:kill() end
    
    -- 如果系统 HDR 不是脚本开启的，不要越权关闭
    if not script_turned_on then return end
    
    if e.reason == "quit" then
        -- 播放器直接退出，必须同步关闭，否则进程销毁后命令无法送达
        mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = {"powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", "& '" .. options.hdr_cmd_path .. "' off"}
        })
        script_turned_on = false
    else
        -- 对于切歌、停止、自然播完等操作，启动延迟关闭倒计时
        if turn_off_timer then turn_off_timer:kill() end
        
        turn_off_timer = mp.add_timeout(options.turn_off_delay, function()
            mp.msg.info("播放结束且无新视频，执行延迟关闭 HDR...")
            mp.osd_message("HDR: 自动恢复 SDR", 3)
            mp.command_native_async({
                name = "subprocess",
                args = {"powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", "& '" .. options.hdr_cmd_path .. "' off"}
            }, function()
                script_turned_on = false
            end)
        end)
    end
end)