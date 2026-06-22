param(
    [ValidateSet("auto", "cpu", "gpu", "both")]
    [string]$Target = "auto",
    [switch]$Recreate,
    [switch]$SkipInstall,
    [switch]$NoSmokeTest,
    [string]$PythonVersion = "3.12",
    [string]$InstallerUrl = "https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe",
    [string[]]$PipArg = @()
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Find-Python {
    $candidates = @()

    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        try {
            $path = (& py "-$PythonVersion" -c "import sys; print(sys.executable)" 2>$null)
            if ($LASTEXITCODE -eq 0 -and $path) { $candidates += $path.Trim() }
        } catch {}
    }

    $local = Join-Path $env:LOCALAPPDATA "Programs\Python"
    if (Test-Path $local) {
        $candidates += Get-ChildItem $local -Recurse -Filter python.exe -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName }
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        try {
            $version = (& $candidate -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null)
            if ($LASTEXITCODE -eq 0 -and $version.Trim() -eq $PythonVersion) {
                return $candidate
            }
        } catch {}
    }
    return $null
}

function Install-Python {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host "Python $PythonVersion not found. Installing with winget..."
        winget install --id "Python.Python.$PythonVersion" --source winget --silent --accept-package-agreements --accept-source-agreements
        $python = Find-Python
        if ($python) { return $python }
        Write-Host "winget finished, but Python was not found on PATH yet. Trying local install paths..."
    }

    Write-Host "Downloading Python installer: $InstallerUrl"
    $tempDir = Join-Path $env:TEMP "cncaptcha-bootstrap"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $installer = Join-Path $tempDir "python-installer.exe"
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $installer

    Write-Host "Installing Python for current user..."
    $installArgs = @(
        "/quiet",
        "InstallAllUsers=0",
        "PrependPath=1",
        "Include_launcher=1",
        "Include_pip=1",
        "Include_test=0"
    )
    $proc = Start-Process -FilePath $installer -ArgumentList $installArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "Python installer failed with exit code $($proc.ExitCode)"
    }

    $python = Find-Python
    if (-not $python) {
        throw "Python was installed, but bootstrap could not find python.exe. Open a new PowerShell and rerun this script."
    }
    return $python
}

$pythonExe = Find-Python
if (-not $pythonExe) {
    $pythonExe = Install-Python
}

Write-Host "Using Python: $pythonExe"
& $pythonExe --version

$argsList = @("scripts\setup_backend.py", "--target", $Target)
if ($Recreate) { $argsList += "--recreate" }
if ($SkipInstall) { $argsList += "--skip-install" }
if ($NoSmokeTest) { $argsList += "--no-smoke-test" }
foreach ($arg in $PipArg) {
    $argsList += "--pip-arg"
    $argsList += $arg
}

& $pythonExe @argsList
