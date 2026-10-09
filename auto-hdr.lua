--[[
    MPV Auto HDR Switcher for Windows
    自动检测 HDR 视频并无缝切换 Windows 系统的 HDR 状态。

    设计要点：
      * 系统 HDR 的真实状态以 HDRCmd.exe 的退出码为准（0=开 / 1=关 / 2=不支持），
        每次决策前异步复核 + 短时缓存，不再使用"启动时读一次"的影子状态，
        因此播放中手动切换 HDR 也不会让脚本判断失真。
      * 视频是否 HDR 以 video-params/gamma 为准（"pq"/"hlg" 即 HDR）；
        gamma 未标记（"auto"）时借助 primaries / sig-peak，最后才用文件名兜底。
      * 只在确实需要切换时才暂停画面，切完回退到开头以避免丢首帧；
        系统本来就处于目标状态时不做任何停顿。
]]

-- ==================== 用户配置区域 ====================
local options = {
    -- HDRCmd.exe 的绝对路径（注意：Lua 中需使用双反斜杠 \\）
    hdr_cmd_path = "C:\\Program Files\\mpv\\HDRCmd.exe",

    -- 防漏帧延迟：显示器切换 HDR/SDR 时的黑屏物理握手时间（秒）。
    -- 开 HDR 的黑屏通常比关更长，故分开配置，可根据自己屏幕的表现微调。
    handshake_delay_on = 3.8,
    handshake_delay_off = 3.8,

    -- 延迟关闭时间：播放结束后延迟关闭 HDR 的缓冲（秒）。
    -- 为切集、选片提供防抖，避免关了又开。
    turn_off_delay = 2.5,

    -- 元数据检测：轮询间隔（秒）与最长等待时间（秒）。
    -- 第一帧解出来之前 video-params 不可用，超过等待时间则启用文件名兜底。
    check_interval = 0.1,
    metadata_timeout = 1.5,

    -- 系统 HDR 状态查询结果的缓存时长（秒），用于合并短时间内的重复查询。
    state_cache_ttl = 1.5,

    -- 调试日志：设为 true 后，mpv 日志里会打印状态查询结果、元数据判定与命令执行结果
    -- 日志前缀是 [auto_hdr]；终端版 mpv.com 直接可见，GUI 版按 ~ 打开控制台查看
    debug = false
}
-- ======================================================

local script_turned_on = false   -- 系统 HDR 是本脚本开启的（决定片尾是否可以关）
local paused_by_script = false   -- 当前暂停是本脚本造成的（只解除自己造成的暂停）
local unpause_timer = nil        -- "握手完成后解除暂停"的定时器
local check_timer = nil          -- 元数据轮询定时器
local turn_off_timer = nil       -- 播放结束后的关机倒计时
local current_playing_path = ""  -- 当前视频路径，用于避免 seek/重载时重复触发检测

-- 系统 HDR 状态缓存：cached_state 为 true/false；nil 表示"不支持 HDR 或查询失败"
local cached_state = nil
local cached_state_valid = false
local cached_state_time = -math.huge
local state_waiters = nil        -- 合并同一时刻的并发查询

-- 注意：mpv 的 mp.msg.* 不做 printf 替换（多个参数会被空格拼接），
-- 需要格式化时必须自己 string.format。
local function log(fmt, ...)
    if options.debug then
        mp.msg.info(string.format(fmt, ...))
    end
end

local function info(fmt, ...)
    mp.msg.info(string.format(fmt, ...))
end

local function err(fmt, ...)
    mp.msg.error(string.format(fmt, ...))
end

-- ==================== HDRCmd 调用层 ====================

-- PowerShell 单引号字符串转义：' -> ''
local function ps_quote(s)
    return "'" .. tostring(s):gsub("'", "''") .. "'"
end

local function hdrcmd_args(extra, pass_exit_code)
    local cmd = "& " .. ps_quote(options.hdr_cmd_path)
    for _, arg in ipairs(extra) do
        cmd = cmd .. " " .. arg
    end
    if pass_exit_code then
        -- powershell -Command 会把任何非 0 退出码压成 1，必须显式透传，
        -- 否则 status 的 2（没有支持 HDR 的显示器）会被误读成 1（HDR 已关闭）
        cmd = cmd .. "; exit $LASTEXITCODE"
    end
    return {"powershell", "-NoProfile", "-WindowStyle", "Hidden", "-Command", cmd}
end

-- 统一的外部调用：始终 capture + playback_only=false，
-- 避免"当前播放项一结束就被 mpv 杀掉子进程"导致命令实际没执行。
local function run_hdrcmd(extra, callback, pass_exit_code)
    local args = {
        name = "subprocess",
        args = hdrcmd_args(extra, pass_exit_code),
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false
    }
    if callback then
        mp.command_native_async(args, callback)
    else
        return mp.command_native(args)
    end
end

-- 是否真的执行成功（进程起不来时 mpv 不抛错，只在结果里体现）
local function hdrcmd_alive(success, result)
    return success and type(result) == "table"
        and result.error_string ~= "init"
        and result.killed_by_us ~= true
end

local function query_hdr_state(callback)
    local now = mp.get_time()
    if cached_state_valid and (now - cached_state_time) < options.state_cache_ttl then
        log("HDR 状态命中缓存：%s", tostring(cached_state))
        callback(cached_state)
        return
    end

    -- 同一时刻的多个请求合并成一次查询
    if state_waiters then
        state_waiters[#state_waiters + 1] = callback
        return
    end
    state_waiters = {callback}

    run_hdrcmd({"status", "-m", "x"}, function(success, result)
        local state = nil
        if hdrcmd_alive(success, result) then
            local code = result.status
            if code == 0 then
                state = true            -- HDR 已开启
            elseif code == 1 then
                state = false           -- HDR 已关闭
            elseif code == 2 then
                state = nil             -- 没有任何支持 HDR 的显示器
            else
                -- Windows 上正常退出也可能得到负值（win32 伪影），退回解析文本
                local out = string.lower(result.stdout or "")
                if out:find("hdr is on", 1, true) then
                    state = true
                elseif out:find("hdr is off", 1, true) then
                    state = false
                end
            end
            log("系统 HDR 状态：%s（退出码 %s）", tostring(state), tostring(code))
        else
            log("系统 HDR 状态查询失败：success=%s error=%s", tostring(success),
                tostring(type(result) == "table" and result.error_string or "?"))
        end

        cached_state = state
        cached_state_valid = true
        cached_state_time = mp.get_time()

        local waiters = state_waiters
        state_waiters = nil
        for _, cb in ipairs(waiters) do
            cb(state)
        end
    end, true)   -- true：透传退出码，才能区分 1(关) 与 2(不支持)
end

-- ==================== 暂停的所有权管理 ====================

local function hold_pause()
    paused_by_script = true
    mp.set_property_bool("pause", true)
end

-- 立即归还暂停（仅当暂停是本脚本造成的）
local function release_pause()
    if unpause_timer then
        unpause_timer:kill()
        unpause_timer = nil
    end
    if paused_by_script then
        paused_by_script = false
        mp.set_property_bool("pause", false)
    end
end

-- 握手完成后归还暂停
local function release_pause_after(delay)
    if unpause_timer then unpause_timer:kill() end
    unpause_timer = mp.add_timeout(delay, function()
        unpause_timer = nil
        if paused_by_script then
            paused_by_script = false
            mp.set_property_bool("pause", false)
        end
    end)
end

-- 丢弃挂起的解除暂停（用于切集：上一部片子的握手不能作用到新文件上）
local function drop_pending_unpause()
    if unpause_timer then
        unpause_timer:kill()
        unpause_timer = nil
    end
end

local function cancel_turn_off_timer()
    if turn_off_timer then
        turn_off_timer:kill()
        turn_off_timer = nil
    end
end

-- ==================== 切换动作 ====================

-- 回退到开头，补齐检测/握手期间已经播掉的画面
local function rewind_if_needed()
    local pos = mp.get_property_number("time-pos", 0)
    if pos and pos > 0 and pos < 2.0 then
        mp.commandv("seek", 0, "absolute+exact")
    end
end

-- 执行一次真正的切换（先暂停，再下发命令，握手完成后恢复播放）
local function do_switch_command(turn_on, trigger_reason)
    local delay = turn_on and options.handshake_delay_on or options.handshake_delay_off
    local action = turn_on and "on" or "off"

    hold_pause()
    rewind_if_needed()
    mp.osd_message(turn_on and "HDR: 正在准备开启..." or "HDR: 正在切回 SDR...", 2)

    run_hdrcmd({action}, function(success, result)
        local alive = hdrcmd_alive(success, result)
        local code = alive and result.status or nil
        log("HDRCmd %s 结束：success=%s status=%s", action, tostring(success), tostring(code))

        local function settle(state)
            if turn_on then
                if state == true then
                    script_turned_on = true
                    mp.msg.info("HDR 已开启（" .. trigger_reason .. "）")
                    mp.osd_message("HDR: 自动开启 (" .. trigger_reason .. ")", 2)
                else
                    script_turned_on = false
                    err("HDR 开启失败，系统状态：%s", tostring(state))
                    mp.osd_message("HDR: 开启失败，请检查 HDRCmd", 3)
                end
            else
                if state == false then
                    script_turned_on = false
                    mp.msg.info("HDR 已关闭（" .. trigger_reason .. "）")
                    mp.osd_message("HDR: 自动恢复 SDR", 2)
                else
                    -- 没关掉就保留标记，后续（片尾/退出）还有机会重试
                    err("HDR 关闭失败，系统状态：%s", tostring(state))
                    mp.osd_message("HDR: 关闭失败，请检查 HDRCmd", 3)
                end
            end
        end

        if code == 0 then
            -- 退出码 0 表示结果与请求一致，直接采信并刷新缓存
            cached_state = turn_on
            cached_state_valid = true
            cached_state_time = mp.get_time()
            settle(turn_on)
        else
            -- 退出码异常：以回读到的真实状态为准，避免"假成功"污染内部状态
            cached_state_valid = false
            query_hdr_state(settle)
        end

        release_pause_after(delay)
    end)
end

-- 供片尾/退出复用的关闭动作（sync=true 用于 mpv 退出前的同步下发）
local function turn_off_hdr(label, sync)
    info("%s：关闭系统 HDR", label)
    mp.osd_message("HDR: 自动恢复 SDR", 3)

    if sync then
        -- 退出路径必须同步阻塞，否则播放器进程销毁后命令送不到
        local res = mp.command_native({
            name = "subprocess",
            playback_only = false,
            args = hdrcmd_args({"off"})
        })
        -- 进程起不来时 mpv 不抛错，只在结果里体现；此时保留标记以便 shutdown 再试一次
        if res and res.error_string ~= "init" and res.killed_by_us ~= true then
            script_turned_on = false
            cached_state = false
            cached_state_valid = true
            cached_state_time = mp.get_time()
        else
            err("退出时关闭 HDR 未成功")
        end
        return
    end

    run_hdrcmd({"off"}, function(success, result)
        if hdrcmd_alive(success, result) then
            script_turned_on = false
            cached_state = false
            cached_state_valid = true
            cached_state_time = mp.get_time()
        else
            err("关闭 HDR 未成功，保留状态标记以便重试")
        end
    end)
end

-- 排定"播放结束后的延迟关闭"（防抖：期间来了新文件会被 start-file 取消）
--
-- 注意：配了 keep-open 时，播到结尾只是暂停在最后一帧，文件不会被卸载，
-- 因此 end-file 不会触发，HDR 保持开启 —— 这是有意的：播完往往还要拖进度条回看。
-- 真正会关闭 HDR 的时机是：退出 mpv、手动 stop（文件被卸载）、或切到 SDR 内容。
local function schedule_turn_off(reason)
    if not script_turned_on then return end
    cancel_turn_off_timer()
    turn_off_timer = mp.add_timeout(options.turn_off_delay, function()
        turn_off_timer = nil
        turn_off_hdr(reason, false)
    end)
end

-- ==================== 核心决策 ====================

-- 依据系统真实状态决定是否需要切换
local function do_hdr_switch(is_movie_hdr, trigger_reason)
    -- 快路径：SDR 内容且系统 HDR 不是本脚本开的 → 无论真实状态如何都无事可做，
    -- 直接放行，省掉一次 PowerShell 查询
    if not is_movie_hdr and not script_turned_on then
        log("SDR 内容且系统 HDR 非本脚本开启，无需处理（%s）", trigger_reason)
        release_pause()
        return
    end

    query_hdr_state(function(sys_hdr)
        if sys_hdr == nil then
            -- 不支持 HDR 或查询失败：不做任何停顿与调用
            log("系统 HDR 状态不可用，跳过本次切换（%s）", trigger_reason)
            mp.osd_message("HDR: 无法获取系统 HDR 状态，已跳过", 2)
            release_pause()
            return
        end

        if is_movie_hdr then
            if sys_hdr then
                mp.msg.info("检测到 HDR，系统已是 HDR，无缝播放（" .. trigger_reason .. "）")
                mp.osd_message("HDR: 无缝衔接 (" .. trigger_reason .. ")", 2)
                release_pause()
            else
                do_switch_command(true, trigger_reason)
            end
        else
            -- 只关自己开的，系统原本的 HDR 状态不越权改动
            if not sys_hdr then
                -- 系统已经是 SDR（例如被手动关掉了），本脚本的标记随之失效
                script_turned_on = false
                release_pause()
            elseif script_turned_on then
                do_switch_command(false, trigger_reason)
            else
                release_pause()
            end
        end
    end)
end

-- 识别文件名中的常见 HDR / 杜比视界标签
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

-- 判定当前视频：返回 "hdr" / "sdr" / "unknown"(需文件名兜底) / "wait"(元数据未就绪)
local function classify_video()
    local gamma = mp.get_property("video-params/gamma", "")
    local primaries = mp.get_property("video-params/primaries", "")
    local sig_peak = mp.get_property_number("video-params/sig-peak", 0)
    local detail = string.format("gamma=%s primaries=%s sig-peak=%s",
        tostring(gamma), tostring(primaries), tostring(sig_peak))

    if gamma == "" then
        -- 整个 video-params 节点还没就绪，继续等第一帧
        return "wait", detail
    end
    if gamma == "pq" or gamma == "hlg" then
        return "hdr", detail
    end
    if gamma == "auto" then
        -- "auto" = 参数已知但传输特性未标记，不会自己变好：
        -- 先用宽色域 / 高亮度这类辅助信号判断，仍不确定则交给文件名
        if primaries == "bt.2020" or (sig_peak and sig_peak > 1.0) then
            return "hdr", detail
        end
        return "unknown", detail
    end
    return "sdr", detail
end

-- ==================== 事件绑定 ====================

-- 新文件开始加载：立刻取消上一集遗留的关机倒计时与解除暂停
mp.register_event("start-file", function()
    cancel_turn_off_timer()
    drop_pending_unpause()
end)

-- 【首帧秒断】：文件名命中 HDR 标签时不必等元数据，直接进入决策
mp.register_event("file-loaded", function()
    local path = mp.get_property("path", "")
    if path == current_playing_path and path ~= "" then return end
    if not is_hdr_filename(mp.get_property("filename", "")) then return end

    current_playing_path = path
    cancel_turn_off_timer()
    if check_timer then check_timer:kill(); check_timer = nil end

    -- 已知系统不是 HDR 时立刻锁住画面；已知已是 HDR 则不停顿，等复核结果
    if not (cached_state_valid and cached_state == true) then
        hold_pause()
    end
    do_hdr_switch(true, "文件名预判")

    -- 预判路径不经过元数据检测，这里补一条快照，便于排查（仅调试模式）
    if options.debug then
        local snapshot_path = path
        mp.add_timeout(1.0, function()
            if mp.get_property("path", "") ~= snapshot_path then return end
            local verdict, detail = classify_video()
            log("（预判路径）元数据快照：%s -> %s", detail, verdict)
        end)
    end
end)

-- 元数据深度检测（playback-restart 也会在 seek 后触发，靠路径去重挡掉）
local function start_checking()
    local path = mp.get_property("path", "")
    if path == current_playing_path and path ~= "" then return end
    current_playing_path = path

    cancel_turn_off_timer()
    if check_timer then check_timer:kill(); check_timer = nil end

    local deadline = mp.get_time() + options.metadata_timeout

    local function check_step()
        local verdict, detail = classify_video()
        log("元数据检测：%s -> %s", detail, verdict)

        if verdict == "wait" and mp.get_time() < deadline then
            return false
        end
        if check_timer then check_timer:kill(); check_timer = nil end

        if verdict == "hdr" then
            do_hdr_switch(true, "元数据")
        elseif verdict == "sdr" then
            do_hdr_switch(false, "元数据")
        elseif is_hdr_filename(mp.get_property("filename", "")) then
            do_hdr_switch(true, "文件名兜底")
        else
            do_hdr_switch(false, verdict == "wait" and "元数据超时" or "元数据未标记")
        end
        return true
    end

    if not check_step() then
        check_timer = mp.add_periodic_timer(options.check_interval, check_step)
    end
end

mp.register_event("playback-restart", start_checking)

-- 播放结束/切集/退出
mp.register_event("end-file", function(e)
    current_playing_path = ""
    if check_timer then check_timer:kill(); check_timer = nil end

    if not script_turned_on then return end

    if e.reason == "quit" then
        -- 播放器直接退出：必须同步下发，否则进程销毁后命令无法送达
        turn_off_hdr("mpv 退出", true)
    else
        -- 其它结束原因（手动 stop、被 loadfile 打断等）：走防抖倒计时。
        -- 播到结尾不算 —— keep-open 下文件没被卸载，end-file 本就不会来。
        schedule_turn_off("播放结束且无新视频")
    end
end)

-- 兜底：空闲状态下退出（没有 end-file）或 --idle 启动时，仍要恢复 SDR
mp.register_event("shutdown", function()
    if script_turned_on then
        turn_off_hdr("mpv 关闭", true)
    end
end)
