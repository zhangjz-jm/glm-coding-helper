param(
    [ValidateSet("auto", "cpu", "gpu")]
    [string]$Target = "auto",
    [int]$Port = 8888,
    [string[]]$PipArg = @()
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

function Test-PythonImports {
    param(
        [string]$PythonPath,
        [string]$Code
    )
    if (-not $PythonPath -or -not (Test-Path $PythonPath)) { return $false }
    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $PythonPath `
            -ArgumentList @("-c", $Code) `
            -Wait `
            -PassThru `
            -NoNewWindow `
            -RedirectStandardOutput $out `
            -RedirectStandardError $err
        return $proc.ExitCode -eq 0
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $err -Force -ErrorAction SilentlyContinue
    }
}

function Has-NvidiaGpu {
    $nvidia = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $nvidia) { return $false }
    & nvidia-smi -L *> $null
    return $LASTEXITCODE -eq 0
}

$Selected = $Target
if ($Selected -eq "auto") {
    $Selected = if (Has-NvidiaGpu) { "gpu" } else { "cpu" }
}

$CpuPython = Join-Path $Root ".venv_paddle\Scripts\python.exe"
$GpuPython = Join-Path $Root ".venv_paddle_gpu\Scripts\python.exe"
$ImportCode = "import ultralytics, paddleocr, paddlex, cv2, PIL, numpy"

$Ready = $false
$SelectedPython = ""
if ($Selected -eq "gpu") {
    $SelectedPython = $GpuPython
    $Ready = Test-PythonImports $GpuPython $ImportCode
} else {
    $SelectedPython = $CpuPython
    $Ready = Test-PythonImports $CpuPython $ImportCode
}

if (-not $Ready) {
    Write-Host "Backend environment is missing or incomplete. Installing $Selected environment..."
    $argsList = @("-Target", $Selected)
    if ($SelectedPython -and (Test-Path $SelectedPython)) {
        Write-Host "Existing backend environment failed import checks. Recreating it..."
        $argsList += "-Recreate"
    }
    foreach ($arg in $PipArg) {
        $argsList += "-PipArg"
        $argsList += $arg
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\bootstrap_windows.ps1" @argsList
}

Write-Host "Starting backend in $Selected mode on port $Port..."
& powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\start_backend.ps1" -Mode $Selected -Port $Port
