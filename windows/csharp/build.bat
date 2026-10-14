@echo off
REM 一键构建「休眠助手」Windows 版（单文件、自包含，目标机器无需装 .NET）
REM 需要本机安装 .NET 8 SDK：https://dotnet.microsoft.com/download/dotnet/8.0
setlocal
cd /d %~dp0

where dotnet >nul 2>nul
if errorlevel 1 (
    echo [错误] 未找到 dotnet，请先安装 .NET 8 SDK。
    echo        https://dotnet.microsoft.com/download/dotnet/8.0
    pause
    exit /b 1
)

echo 正在发布 win-x64 自包含单文件...
dotnet publish -c Release -r win-x64 --self-contained true ^
    /p:PublishSingleFile=true /p:EnableCompressionInSingleFile=true -o publish
if errorlevel 1 (
    echo [失败] 构建出错，请看上面日志。
    pause
    exit /b 1
)

echo.
echo 完成：publish\SleepAssistant.exe
echo 双击即可运行（首次设置“合盖不休眠”会弹一次 UAC 管理员授权）。
pause
