@echo off
rem ============================================================
rem  测试用的假 HDRCmd 替身（run-tests.ps1 会把它复制到临时目录后调用）
rem
rem  行为：
rem    status   有 state.on 时返回 0 表示开；有 mode-unsupported 时返回 2 表示不支持；否则返回 1 表示关
rem    on       写 state.on 后返回 0；存在 mode-fail 时返回 3 模拟失败
rem    off      删 state.on 后返回 0
rem
rem  每次调用都往 calls.log 追加一行，便于断言调用序列。
rem  两个注意点：日志必须写成方括号形式，因为 cmd 里单独一句 echo on 或 echo off 是特殊词，
rem  不会输出内容还会顺手切换回显；另外这里刻意不用带括号的多行 if 块，
rem  因为 cmd 解析块内的 if 加 exit 时行为不可靠。
rem ============================================================
>>"%~dp0calls.log" echo [%1]
if /i "%1"=="status" goto :status
if /i "%1"=="on" goto :on
if /i "%1"=="off" goto :off
exit /b 0

:status
if exist "%~dp0mode-unsupported" exit /b 2
if exist "%~dp0state.on" exit /b 0
exit /b 1

:on
if exist "%~dp0mode-fail" exit /b 3
>"%~dp0state.on" echo x
exit /b 0

:off
if exist "%~dp0state.on" del "%~dp0state.on"
exit /b 0
