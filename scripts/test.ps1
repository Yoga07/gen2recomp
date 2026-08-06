# Run the decoder tests headlessly and print the report.
#
#   scripts\test.ps1 -Rom "C:\path\to\Pokemon Crystal.gbc"
#
# LOVE is a windowed binary with no usable stdout on Windows, so the harness
# writes its report to a file and this script reads it back. Arguments are
# quoted individually because Start-Process joins an argument array with spaces
# without quoting, which silently mangles any path containing a space.

param(
    [Parameter(Mandatory = $true)][string]$Rom,
    [string]$Love = $env:LOVE_EXE,
    [string]$Report
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot

if (-not $Love) {
    $cmd = Get-Command love -ErrorAction SilentlyContinue
    if ($cmd) { $Love = $cmd.Source }
}
if (-not $Love -or -not (Test-Path $Love)) {
    throw "love.exe not found. Pass -Love <path> or set the LOVE_EXE environment variable."
}
if (-not (Test-Path $Rom)) {
    throw "ROM not found: $Rom"
}
if (-not $Report) {
    $Report = Join-Path ([System.IO.Path]::GetTempPath()) 'gen2recomp-test.txt'
}
if (Test-Path $Report) { Remove-Item $Report }

$quoted = @(
    ('"{0}"' -f $projectRoot),
    '--test',
    ('"{0}"' -f $Rom),
    ('"{0}"' -f $Report)
)

$sw = [Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $Love -ArgumentList $quoted -Wait -PassThru -NoNewWindow
$sw.Stop()

if (Test-Path $Report) {
    Get-Content $Report -Raw
} else {
    Write-Error "harness produced no report"
}

Write-Host ("`nexit {0} in {1:N1}s" -f $proc.ExitCode, $sw.Elapsed.TotalSeconds)
exit $proc.ExitCode
