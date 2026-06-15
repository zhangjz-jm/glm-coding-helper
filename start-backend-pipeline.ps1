# GLM Coding Helper - Pipeline Backend Launcher
# Usage: powershell -File start-backend-pipeline.ps1
#   or double-click start-backend-pipeline.cmd

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

Write-Host "GLM Coding Helper - Pipeline Backend" -ForegroundColor Cyan
Write-Host ""

# ── 查找 Python venv ──
$Python = ""
if (Test-Path "$Root\venv\Scripts\python.exe") {
    $Python = "$Root\venv\Scripts\python.exe"
} elseif (Test-Path "$Root\.venv_paddle\Scripts\python.exe") {
    $Python = "$Root\.venv_paddle\Scripts\python.exe"
} else {
    Write-Host "[失败] 未找到 Python 虚拟环境，请先运行安装脚本。" -ForegroundColor Red
    Write-Host "[FAIL] No Python venv found. Run setup first (one-click-start.cmd / install-env.cmd)." -ForegroundColor Red
    Read-Host "按 Enter 退出"
    exit 1
}

Write-Host "[信息] 使用 Python: $Python" -ForegroundColor Gray

# ── 依赖检查 ──
$depsCheck = & $Python -c "import fastapi, uvicorn, psutil" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "[警告] 当前后端环境缺少 pipeline 依赖 (fastapi/uvicorn/psutil)。" -ForegroundColor Yellow
    Write-Host "[WARN] Missing pipeline backend dependencies. Environment needs repair." -ForegroundColor Yellow
    Write-Host ""

    # 尝试自动调用 setup_backend.ps1
    $setupScript = "$Root\scripts\setup_backend.ps1"
    if (Test-Path $setupScript) {
        Write-Host "是否自动安装缺失的依赖？"
        Write-Host "Install missing dependencies automatically?"
        $choice = Read-Host "输入 1 自动安装 / Enter 退出 (1=install / Enter=exit)"
        if ($choice -eq "1") {
            Write-Host "[信息] 正在安装 pipeline 依赖..." -ForegroundColor Cyan
            $env:PYTHONUTF8 = "1"
            $env:PYTHONIOENCODING = "utf-8"
            # 直接 pip install 到当前 venv
            & $Python -m pip install fastapi "uvicorn[standard]" psutil --quiet
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[失败] 自动安装失败，请手动运行: install-env.cmd" -ForegroundColor Red
                Write-Host "[FAIL] Auto-install failed. Run manually: install-env.cmd" -ForegroundColor Red
                Read-Host "按 Enter 退出"
                exit 1
            }
            Write-Host "[完成] 依赖安装成功" -ForegroundColor Green
        } else {
            Write-Host "请手动运行 install-env.cmd 或 pip install fastapi uvicorn psutil 后重试。" -ForegroundColor Yellow
            Read-Host "按 Enter 退出"
            exit 1
        }
    } else {
        Write-Host "请手动运行: $Python -m pip install fastapi uvicorn psutil" -ForegroundColor Yellow
        Read-Host "按 Enter 退出"
        exit 1
    }
}

# ── 端口检查 ──
$portLines = netstat -ano | Select-String ":8888 .*LISTENING"
if ($portLines) {
    $line = $portLines[0].ToString().Trim()
    $parts = $line -split '\s+'
    $portPid = $parts[-1]

    # 获取进程信息
    $procName = ""
    $procCmd = ""
    try {
        $proc = Get-Process -Id $portPid -ErrorAction SilentlyContinue
        if ($proc) { $procName = $proc.ProcessName }
        $procCmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$portPid" -ErrorAction SilentlyContinue).CommandLine
        if (-not $procCmd) { $procCmd = "" }
    } catch {}

    Write-Host ""
    Write-Host "[警告] 端口 8888 已被占用，后端可能已经在运行。" -ForegroundColor Yellow
    Write-Host "[WARN] Port 8888 is already in use. The backend may already be running." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "占用进程:" -ForegroundColor DarkYellow
    Write-Host "  PID      : $portPid"
    if ($procName) { Write-Host "  进程名   : $procName" }
    if ($procCmd) { Write-Host "  命令行   : $procCmd" }
    Write-Host ""
    Write-Host "请选择:"
    Write-Host "  1 - 关闭该进程并重新启动后端"
    Write-Host "  Enter - 不处理，直接退出"
    Write-Host ""
    Write-Host "Choose:"
    Write-Host "  1 - Stop this process and restart backend"
    Write-Host "  Enter - Exit without changing anything"
    Write-Host ""

    $choice = Read-Host "输入 (Input)"
    if ($choice -eq "1") {
        Write-Host "[信息] 正在关闭 PID $portPid ..." -ForegroundColor Cyan
        Stop-Process -Id $portPid -Force -ErrorAction SilentlyContinue
        Start-Sleep 3
        Write-Host "[完成] 已关闭。" -ForegroundColor Green
    } else {
        exit 1
    }
}

Write-Host "[信息] 正在启动 pipeline 后端 http://127.0.0.1:8888" -ForegroundColor Green
Write-Host "[提示] 首次启动需要加载模型 (~10秒)，请等待 worker 就绪。" -ForegroundColor DarkYellow
Write-Host "[信息] Ctrl+C 停止" -ForegroundColor Gray
Write-Host ""

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

& $Python "$Root\backend\server.py"

Read-Host "按 Enter 退出"
