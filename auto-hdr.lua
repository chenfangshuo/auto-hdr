--[[
    MPV Auto HDR Switcher for Windows
    自动检测 HDR 视频并无缝切换 Windows 系统的 HDR 状态。
]]

-- ==================== 用户配置区域 ====================
local options = {
    -- HDRCmd.exe 的绝对路径（注意：Lua 中需使用双反斜杠 \\）
    hdr_cmd_path = "C:\\Program Files\\mpv\\HDRCmd.exe",
    
    -- 防漏帧延迟：显示器切换 HDR/SDR 时的黑屏物理握手时间（秒）
    handshake_delay = 3.8,
    
    -- 延迟关闭时间：播放结束时，延迟关闭 HDR 的时间（秒）
    turn_off_delay = 2.5,
    
    -- 底层数据检测超时阈值（轮询检测最大次数）
    max_check_attempts = 25
}
-- ======================================================

local script_turned_on = false 
local check_timer = nil
local turn_off_timer = nil
local current_playing_path = ""

-- 查询 Windows 当前 HDR 实际状态
local function check_powershell_status()
    local res = mp.command_native({
        name = "subprocess",
        args = {"powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", "& '" .. options.hdr_cmd_path .. "' status"},
        capture_stdout = true,
        capture_stderr = true
    })
    local out = res and res.stdout or ""
    local lower_out = string.lower(out)
    return (string.find(lower_out, "on") ~= nil) or (string.find(lower_out, "1") ~= nil)
end

-- 启动时在内存中初始化状态，后续由 Lua 追踪
local is_sys_hdr = check_powershell_status()

-- 准确识别文件名中的常见 HDR / 杜比视界标签
local function is_hdr_filename(name)
    if not name or name == "" then return false end
    local lower = string.lower(name)
    if string.find(lower, "hdr") 
       or string.find(lower, "dovi") 
       or string.find(lower, "dolby[%s%.%-_]?vision")
       or string.find(lower, "[%s%.%-_]dv[%s%.%-_]")
       or string.find(lower, "smpte2084")
       or string.find(lower, "hlg") then
        return true
    end
    return false
end

-- 核心切换逻辑
function do_hdr_switch(is_movie_hdr, trigger_reason)
    if is_movie_hdr then
        if not is_sys_hdr then
            mp.msg.info("检测到 HDR (" .. trigger_reason .. ")，正在开启...")
            
            -- 1. 0 延迟立即暂停
            mp.set_property_bool("pause", true)
            mp.osd_message("HDR: 正在准备开启...", 2)

            -- 2. 若在元数据初始化期间漏跑了零点几秒，自动精准回退至开头
            local pos = mp.get_property_number("time-pos", 0)
            if pos > 0 and pos < 2.0 then
                mp.commandv("seek", 0, "absolute", "exact")
            end

            -- 3. 异步下发开启命令
            mp.command_native_async({
                name = "subprocess",
                args = {"powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", "& '" .. options.hdr_cmd_path .. "' on"}
            }, function()
                is_sys_hdr = true
                script_turned_on = true
                mp.osd_message("HDR: 自动开启 (" .. trigger_reason .. ")", 2)
                
                -- 等待显示器硬件握手完成后恢复播放
                mp.add_timeout(options.handshake_delay, function()
                    mp.set_property_bool("pause", false)
                end)
            end)
        else
            mp.msg.info("检测到 HDR，且系统已在 HDR 状态，无缝播放。")
            mp.osd_message("HDR: 无缝衔接 (" .. trigger_reason .. ")", 2)
        end
    else
        -- 播放 SDR 且当前 HDR 是本脚本开启的，执行恢复
        if is_sys_hdr and script_turned_on then
            mp.msg.info("检测到 SDR 视频，正在关闭系统 HDR...")

            -- 1. 立即暂停 SDR 播放，防止黑屏期间漏帧
            mp.set_property_bool("pause", true)
            mp.osd_message("HDR: 正在切回 SDR...", 2)

            -- 2. 重置进度到开头
            local pos = mp.get_property_number("time-pos", 0)
            if pos > 0 and pos < 2.0 then
                mp.commandv("seek", 0, "absolute", "exact")
            end

            -- 3. 异步关闭 HDR
            mp.command_native_async({
                name = "subprocess",
                args = {"powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", "& '" .. options.hdr_cmd_path .. "' off"}
            }, function()
                is_sys_hdr = false
                script_turned_on = false
                mp.osd_message("HDR: 自动恢复 SDR", 2)

                -- 4. 同样等待 3.8 秒硬件握手完成后再解除暂停
                mp.add_timeout(options.handshake_delay, function()
                    mp.set_property_bool("pause", false)
                end)
            end)
        end
    end
end

-- 【首帧秒断】：文件载入的第一时间尝试预判
mp.register_event("file-loaded", function()
    local path = mp.get_property("path", "")
    if path == current_playing_path and path ~= "" then return end
    
    local filename = mp.get_property("filename", "")
    if is_hdr_filename(filename) and not is_sys_hdr then
        -- 命中 HDR 标签且系统为 SDR 时，在第 0 帧彻底锁住播放状态
        mp.set_property_bool("pause", true)
        current_playing_path = path
        if turn_off_timer then turn_off_timer:kill(); turn_off_timer = nil end
        do_hdr_switch(true, "文件名预判")
    end
end)

-- 视频加载时的元数据深度检测
function start_checking()
    local path = mp.get_property("path", "")
    if path == current_playing_path and path ~= "" then
        return
    end
    current_playing_path = path

    if turn_off_timer then 
        turn_off_timer:kill()
        turn_off_timer = nil
    end

    local attempts = 0
    if check_timer then check_timer:kill() end
    
    local function check_step()
        attempts = attempts + 1
        
        local gamma = mp.get_property("video-params/gamma", "")
        local color_trc = mp.get_property("video-params/color-trc", "")
        local filename = mp.get_property("filename", "")
        
        local is_hdr = false
        local reason = ""
        
        if gamma == "pq" or gamma == "hlg" then
            is_hdr = true
            reason = "Gamma"
        elseif color_trc == "smpte2084" or color_trc == "pq" or color_trc == "hlg" then
            is_hdr = true
            reason = "TRC"
        end
        
        if (gamma ~= "" and gamma ~= "unknown") or (color_trc ~= "" and color_trc ~= "unknown") then
            if check_timer then check_timer:kill(); check_timer = nil end
            do_hdr_switch(is_hdr, reason)
            return true
        elseif attempts > options.max_check_attempts then
            if check_timer then check_timer:kill(); check_timer = nil end
            if is_hdr_filename(filename) then
                do_hdr_switch(true, "文件名兜底")
            else
                do_hdr_switch(false, "SDR")
            end
            return true
        end
        return false
    end

    -- 立即执行第 1 次检测
    if not check_step() then
        check_timer = mp.add_periodic_timer(0.1, check_step)
    end
end

mp.register_event("playback-restart", start_checking)

-- 视频结束/退出处理
mp.register_event("end-file", function(e)
    current_playing_path = ""
    if check_timer then check_timer:kill(); check_timer = nil end
    
    if not script_turned_on then return end
    
    if e.reason == "quit" then
        mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = {"powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", "& '" .. options.hdr_cmd_path .. "' off"}
        })
        is_sys_hdr = false
        script_turned_on = false
    else
        if turn_off_timer then turn_off_timer:kill() end
        turn_off_timer = mp.add_timeout(options.turn_off_delay, function()
            mp.msg.info("播放结束且无新视频，执行延迟关闭 HDR...")
            mp.osd_message("HDR: 自动恢复 SDR", 3)
            mp.command_native_async({
                name = "subprocess",
                args = {"powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", "& '" .. options.hdr_cmd_path .. "' off"}
            }, function()
                is_sys_hdr = false
                script_turned_on = false
            end)
        end)
    end
end)
