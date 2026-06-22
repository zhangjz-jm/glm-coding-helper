param(
    [ValidateSet("auto", "cpu", "gpu", "both")]
    [string]$Target = "auto",
    [switch]$Recreate,
    [switch]$SkipInstall,
    [switch]$NoSmokeTest,
    [string[]]$PipArg = @()
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$argsList = @("scripts\setup_backend.py", "--target", $Target)
if ($Recreate) { $argsList += "--recreate" }
if ($SkipInstall) { $argsList += "--skip-install" }
if ($NoSmokeTest) { $argsList += "--no-smoke-test" }
foreach ($arg in $PipArg) {
    $argsList += "--pip-arg"
    $argsList += $arg
}

python @argsList
