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
    $OutFile = [System.IO.Path]::GetTempFileName()
    $ErrFile = [System.IO.Path]::GetTempFileName()
    try {
        $Proc = Start-Process -FilePath $PythonPath `
            -ArgumentList @("-c", "import ultralytics, PIL, cv2, numpy") `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $OutFile `
            -RedirectStandardError $ErrFile
        return $Proc.ExitCode -eq 0
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $ErrFile -Force -ErrorAction SilentlyContinue
    }
}

if (-not $env:CNCAPTCHA_CPU_OCR_PYTHON) {
    $CpuPython = Find-AncestorVenvPython -StartDir $Root -VenvName ".venv_paddle"
    if ($CpuPython) { $env:CNCAPTCHA_CPU_OCR_PYTHON = $CpuPython }
}
if (-not $env:CNCAPTCHA_GPU_OCR_PYTHON) {
    $GpuPython = Find-AncestorVenvPython -StartDir $Root -VenvName ".venv_paddle_gpu"
    if ($GpuPython) { $env:CNCAPTCHA_GPU_OCR_PYTHON = $GpuPython }
}

$MainPython = ""
if ((Test-BackendMainPython $env:CNCAPTCHA_CPU_OCR_PYTHON)) {
    $MainPython = $env:CNCAPTCHA_CPU_OCR_PYTHON
} elseif ((Test-BackendMainPython $env:CNCAPTCHA_GPU_OCR_PYTHON)) {
    $MainPython = $env:CNCAPTCHA_GPU_OCR_PYTHON
} else {
    $MainPython = "python"
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

& $MainPython @argsList
