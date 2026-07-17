param(
    [ValidateSet("auto", "gpu", "cpu", "cpu_parallel")]
    [string]$Mode = "auto",
    [switch]$Headless,
    [int]$Port = 8888,
    [int]$CpuWorkers = 0,
    [string]$YoloDevice = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

function Find-AncestorVenvPython {
    param(
        [string]$StartDir,
        [string]$VenvName
    )
    $Dir = (Resolve-Path $StartDir).Path
    for ($i = 0; $i -lt 5 -and $Dir; $i++) {
        $Candidate = Join-Path $Dir "$VenvName\Scripts\python.exe"
        if (Test-Path $Candidate) {
            return $Candidate
        }
        $Parent = Split-Path -Parent $Dir
        if ($Parent -eq $Dir) { break }
        $Dir = $Parent
    }
    return ""
}

function Test-BackendMainPython {
    param([string]$PythonPath)
    if (-not $PythonPath) { return $false }
    if ($PythonPath -ne "python" -and -not (Test-Path $PythonPath)) { return $false }
    try {
        & $PythonPath -c "import ultralytics, PIL, cv2, numpy; from paddleocr import TextRecognition" *> $null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Select-BackendMainPython {
    param(
        [string]$RequestedMode,
        [string]$CpuPython,
        [string]$GpuPython
    )

    if ($RequestedMode -eq "gpu") {
        if ((Test-BackendMainPython $GpuPython)) { return $GpuPython }
        throw "GPU backend environment is missing or incomplete: $GpuPython. Run one-click-start.cmd, or rebuild it with: powershell -ExecutionPolicy Bypass -File scripts\bootstrap_windows.ps1 -Target gpu -Recreate"
    }

    if ($RequestedMode -eq "cpu" -or $RequestedMode -eq "cpu_parallel") {
        if ((Test-BackendMainPython $CpuPython)) { return $CpuPython }
        throw "CPU backend environment is missing or incomplete: $CpuPython. Run one-click-start.cmd, or rebuild it with: powershell -ExecutionPolicy Bypass -File scripts\bootstrap_windows.ps1 -Target cpu -Recreate"
    }

    if ((Test-BackendMainPython $GpuPython)) { return $GpuPython }
    if ((Test-BackendMainPython $CpuPython)) { return $CpuPython }
    throw "No usable backend environment found. Run one-click-start.cmd to install or repair the backend environment."
}

if (-not $env:CNCAPTCHA_CPU_OCR_PYTHON) {
    $CpuPython = Find-AncestorVenvPython -StartDir $Root -VenvName ".venv_paddle"
    if ($CpuPython) { $env:CNCAPTCHA_CPU_OCR_PYTHON = $CpuPython }
}
if (-not $env:CNCAPTCHA_GPU_OCR_PYTHON) {
    $GpuPython = Find-AncestorVenvPython -StartDir $Root -VenvName ".venv_paddle_gpu"
    if ($GpuPython) { $env:CNCAPTCHA_GPU_OCR_PYTHON = $GpuPython }
}

$MainPython = Select-BackendMainPython `
    -RequestedMode $Mode `
    -CpuPython $env:CNCAPTCHA_CPU_OCR_PYTHON `
    -GpuPython $env:CNCAPTCHA_GPU_OCR_PYTHON

# 端口占用预检测：8888 被占会导致 WinError 10013/10048，提前提示并尝试给出占用进程信息。
try {
    $inUse = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
} catch {
    $inUse = $null
}
if ($inUse) {
    $ownPids = $inUse | Select-Object -ExpandProperty OwningProcess -Unique
    Write-Host ""
    Write-Host "[警告] 端口 $Port 已被占用，后端可能启动失败（WinError 10013/10048）。" -ForegroundColor Yellow
    foreach ($procId in $ownPids) {
        try {
            $proc = Get-Process -Id $procId -ErrorAction Stop
            Write-Host "       占用进程: PID=$procId  名称=$($proc.ProcessName)  路径=$($proc.Path)" -ForegroundColor Yellow
        } catch {
            Write-Host "       占用进程: PID=$procId  (无法获取详情，可能已退出)" -ForegroundColor Yellow
        }
    }
    Write-Host "       可能原因：① 之前后端没退干净；② 别的软件占了 $Port（迅雷/代理/其它本地服务）。" -ForegroundColor Yellow
    Write-Host "       解决：任务管理器结束上面的 PID，或关掉占用软件，再重新启动。" -ForegroundColor Yellow
    Write-Host "       也可以用别的端口：one-click-start.cmd 改为 powershell -File scripts\one_click_start.ps1 -Port 8889" -ForegroundColor Yellow
    Write-Host ""
}

$argsList = @("scripts\tools\start_backend.py", "--mode", $Mode, "--port", "$Port")
if ($Headless) { $argsList += "--headless" }
if ($CpuWorkers -gt 0) {
    $argsList += "--cpu-workers"
    $argsList += "$CpuWorkers"
}
if ($YoloDevice) {
    $argsList += "--yolo-device"
    $argsList += $YoloDevice
}

Write-Host "Using backend Python: $MainPython"
& $MainPython @argsList
