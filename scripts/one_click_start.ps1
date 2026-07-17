param(
    [ValidateSet("auto", "cpu", "gpu")]
    [string]$Target = "auto",
    [int]$Port = 8888,
    # 默认空数组；用户不传 -PipArg 时，运行时自动探测可用 PyPI 镜像（见 Select-PypiMirror）。
    [string[]]$PipArg = @()
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

# PyPI 镜像列表（国内优先，官方兜底）。Select-PypiMirror 会按顺序探测，选第一个可用的。
$script:PypiMirrors = @(
    "https://pypi.tuna.tsinghua.edu.cn/simple",
    "https://mirrors.aliyun.com/pypi/simple",
    "https://pypi.mirrors.ustc.edu.cn/simple",
    "https://mirrors.cloud.tencent.com/pypi/simple",
    "https://pypi.org/simple"
)

function Select-PypiMirror {
    # 依次 HEAD 探测每个镜像，3 秒超时，返回第一个通的（含 https + simple 结尾校验）。
    foreach ($url in $script:PypiMirrors) {
        try {
            $probe = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
            if ($probe.StatusCode -ge 200 -and $probe.StatusCode -lt 500) {
                Write-Host "PyPI 镜像可用: $url" -ForegroundColor Green
                return $url
            }
        } catch {
            Write-Host "PyPI 镜像不可用: $url ($($_.Exception.Message -split "`n")[0])" -ForegroundColor DarkGray
        }
    }
    # 全挂了，回退官方源（让 pip 自己报错，至少有明确信息）
    Write-Host "所有镜像探测失败，回退官方源 pypi.org" -ForegroundColor Yellow
    return "https://pypi.org/simple"
}

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

function Warn-LongInstallPath {
    # Some backend deps contain very deep package paths. A long extract path can hit
    # Windows MAX_PATH during pip install even when all release files are present.
    # 阈值 60 基于实测：.venv_paddle 内最长相对路径 177 字符（modelscope/custom_datasets），
    # 完整路径 = Root + 1 + 177，MAX_PATH=260，所以 Root 安全上限约 82；
    # 取 60 留 22 字符余量给 pip 临时文件，超过即提示。
    if ($Root.Length -gt 60) {
        Write-Host "[警告] 当前文件夹路径偏长（$($Root.Length) 字符）: $Root" -ForegroundColor Yellow
        Write-Host "       后端依赖包内部路径很深，路径太长会导致 pip 安装时报 'No such file or directory'。" -ForegroundColor Yellow
        Write-Host "       建议移动到短路径如 C:\glm-coding-helper 后再运行。" -ForegroundColor Yellow
        Write-Host ""
    }
}

function Assert-RequiredFiles {
    $required = @(
        "scripts\bootstrap_windows.ps1",
        "scripts\start_backend.ps1",
        "scripts\setup_backend.py",
        "requirements-backend-cpu.txt",
        "requirements-backend-gpu.txt"
    )
    $missing = @()
    foreach ($rel in $required) {
        if (-not (Test-Path (Join-Path $Root $rel))) {
            $missing += $rel
        }
    }
    if ($missing.Count -gt 0) {
        Write-Host "[FAIL] Release package is incomplete. Missing files:" -ForegroundColor Red
        foreach ($item in $missing) {
            Write-Host "       - $item" -ForegroundColor Red
        }
        Write-Host "Please re-extract the full latest release zip and retry." -ForegroundColor Yellow
        Read-Host "Press Enter to exit"
        exit 1
    }
}

function Test-PythonImports {
    param(
        [string]$PythonPath,
        [string]$Code
    )
    if (-not $PythonPath -or -not (Test-Path $PythonPath)) { return $false }
    try {
        & $PythonPath -c $Code *> $null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Test-ForeignVenv {
    param(
        [string]$VenvDir
    )
    if (-not $VenvDir -or -not (Test-Path $VenvDir)) { return $false }
    $cfg = Join-Path $VenvDir "pyvenv.cfg"
    if (-not (Test-Path $cfg)) { return $true }
    try {
        $text = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8
    } catch {
        return $true
    }
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^(executable|command)\s*=\s*(.+)$') {
            $value = $Matches[2].Trim()
            if ($value -match 'C:\\Users\\17336\\') { return $true }
            if ($line -match '^executable\s*=' -and -not (Test-Path $value)) { return $true }
        }
        if ($line -match '^command\s*=.*\s-m\s+venv\s+(.+)$') {
            $createdAt = $Matches[1].Trim().Trim('"')
            try {
                $expected = (Resolve-Path -LiteralPath $VenvDir -ErrorAction Stop).Path
                if ([IO.Path]::GetFullPath($createdAt).TrimEnd('\') -ne $expected.TrimEnd('\')) { return $true }
            } catch {
                return $true
            }
        }
    }
    return $false
}

function Has-NvidiaGpu {
    $nvidia = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $nvidia) { return $false }
    & nvidia-smi -L *> $null
    return $LASTEXITCODE -eq 0
}

function Invoke-Bootstrap {
    param(
        [string]$BootstrapTarget,
        [string]$PythonPath,
        [switch]$ForceRecreate
    )
    $argsList = @("-Target", $BootstrapTarget)
    if ($ForceRecreate -or ($PythonPath -and (Test-Path $PythonPath))) {
        Write-Host "Existing backend environment failed portability/import checks. Recreating it..."
        $argsList += "-Recreate"
    }
    # 用分号把所有 pip 参数拼成单个字符串传递，避免 "-i" 等 dash 开头的值
    # 被 PowerShell 当成下一个参数名（"Missing an argument for parameter 'PipArg'"）
    if ($PipArg -and $PipArg.Count) {
        $argsList += "-PipArg"
        $argsList += ($PipArg -join ";")
    }
    # 把 bootstrap 完整输出同时写日志文件，便于失败时诊断
    $logPath = Join-Path $Root "logs\backend-install.log"
    $logDir = Split-Path -Parent $logPath
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Write-Host "详细安装日志: $logPath"
    # 用外部 powershell 进程跑 bootstrap（参数 splatting 在外部进程下可靠，
    # 进程内 & script.ps1 @args 会把 "-Target" 当值而非参数名）。
    # 不用 | Tee 管道（会缓冲，用户看不到 pip 进度）；子进程 stdout 直接继承当前控制台。
    # 日志由 bootstrap 内部写（setup_backend.py 的 print 都带 flush=True）。
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$Root\scripts\bootstrap_windows.ps1" @argsList
    $code = $LASTEXITCODE
    # 把退出码写进日志尾部，便于诊断
    try { Add-Content -Path $logPath -Value "[one_click_start] bootstrap exit code: $code" -Encoding UTF8 } catch {}
    return $code
}

Assert-RequiredFiles
Warn-LongInstallPath

$InstallTarget = $Target
if ($InstallTarget -eq "auto") {
    $InstallTarget = if (Has-NvidiaGpu) { "gpu" } else { "cpu" }
}

$CpuPython = Join-Path $Root ".venv_paddle\Scripts\python.exe"
$GpuPython = Join-Path $Root ".venv_paddle_gpu\Scripts\python.exe"
$CpuVenv = Join-Path $Root ".venv_paddle"
$GpuVenv = Join-Path $Root ".venv_paddle_gpu"
$ImportCode = "import ultralytics, paddleocr, paddlex, cv2, PIL, numpy"

$SelectedPython = if ($InstallTarget -eq "gpu") { $GpuPython } else { $CpuPython }
$SelectedVenv = if ($InstallTarget -eq "gpu") { $GpuVenv } else { $CpuVenv }
$NeedsRecreate = Test-ForeignVenv $SelectedVenv
if ($NeedsRecreate) {
    Write-Host "[WARN] Existing backend environment was created on another machine or in another folder. It will be rebuilt locally." -ForegroundColor Yellow
}
$Ready = (-not $NeedsRecreate) -and (Test-PythonImports $SelectedPython $ImportCode)

if (-not $Ready) {
    Write-Host "Backend environment is missing or incomplete (PIL/cv2/numpy etc). Installing $InstallTarget environment..."
    # 用户没显式传 -PipArg 时，自动探测可用 PyPI 镜像（避免单源挂了导致安装失败）
    if (-not $PipArg -or $PipArg.Count -eq 0) {
        $mirror = Select-PypiMirror
        $PipArg = @("-i", $mirror)
    }
    $bootstrapExit = Invoke-Bootstrap -BootstrapTarget $InstallTarget -PythonPath $SelectedPython -ForceRecreate:$NeedsRecreate
    $SelectedPython = if ($InstallTarget -eq "gpu") { $GpuPython } else { $CpuPython }
    $Ready = Test-PythonImports $SelectedPython $ImportCode

    if (($bootstrapExit -ne 0 -or -not $Ready) -and $Target -eq "auto" -and $InstallTarget -eq "gpu") {
        Write-Host "[WARN] GPU bootstrap failed or remained incomplete. Falling back to CPU environment..." -ForegroundColor Yellow
        $InstallTarget = "cpu"
        $SelectedPython = $CpuPython
        $bootstrapExit = Invoke-Bootstrap -BootstrapTarget "cpu" -PythonPath $SelectedPython
        $Ready = Test-PythonImports $SelectedPython $ImportCode
    }

    if (-not $Ready) {
        Write-Host "[失败] 后端环境修复失败，依赖仍缺失。" -ForegroundColor Red
        if ($Target -eq "auto") {
            Write-Host "       auto 模式已尝试 GPU/CPU 回退。" -ForegroundColor Red
        }
        # 主动检测路径长度——pip 失败最常见的原因之一是 Windows MAX_PATH 限制
        if ($Root.Length -gt 60) {
            Write-Host ""
            Write-Host "       ⚠️ 当前路径偏长（$($Root.Length) 字符），pip 失败很可能是 Windows 路径长度限制导致。" -ForegroundColor Yellow
            Write-Host "       把整个文件夹移到短路径（如 C:\glm-coding-helper）后重新双击 one-click-start.cmd 再试。" -ForegroundColor Yellow
            Write-Host ""
        }
        Write-Host "       其它排查：重新解压最新 Release 包重跑；确认 Python 版本是 3.12。" -ForegroundColor Red
        Write-Host "       完整安装日志已保存到 logs\backend-install.log，排查请提供此文件。" -ForegroundColor Yellow
        Read-Host "按 Enter 退出"
        exit 1
    }
}

if ($Target -eq "auto" -and $InstallTarget -eq "gpu" -and -not (Test-PythonImports $CpuPython $ImportCode)) {
    Write-Host "CPU fallback environment is missing. Installing CPU environment for auto fallback..."
    $fallbackExit = Invoke-Bootstrap -BootstrapTarget "cpu" -PythonPath $CpuPython
    if ($fallbackExit -ne 0) {
        Write-Host "[WARN] CPU fallback environment installation failed. Auto mode will still try GPU first." -ForegroundColor Yellow
    }
}

$PipelineDepsOk = Test-PythonImports $SelectedPython "import fastapi, uvicorn, psutil"
if (-not $PipelineDepsOk) {
    Write-Host "[INFO] Pipeline backend deps (fastapi/uvicorn/psutil) not installed. Run start-backend-pipeline-gui.cmd to add them." -ForegroundColor Yellow
}

$StartMode = if ($Target -eq "auto") { "auto" } else { $InstallTarget }
Write-Host "Starting backend in $StartMode mode on port $Port..."
& powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\start_backend.ps1" -Mode $StartMode -Port $Port
