$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Python = Get-Command python -ErrorAction SilentlyContinue

if (-not $Python) {
    Write-Error "python was not found in PATH"
    exit 2
}

& $Python.Source (Join-Path $RootDir "scripts\belkasql.py") @args
exit $LASTEXITCODE
