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
    [string]$Report,
    # An optional second cartridge that is deliberately not Gen 2. When given,
    # the suite checks that every locator refuses it rather than decoding
    # plausible garbage out of it. Skipped when absent.
    [string]$Other
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot

if (-not $Love) {
    $cmd = Get-Command love -ErrorAction SilentlyContinue
    if ($cmd) { $Love = $cmd.Source }
}
# -LiteralPath throughout: Test-Path treats [ ] as a wildcard bracket, and ROM
# filenames from the usual dump sets are full of them ("Pokemon Red (UE)[!].gb"),
# so a plain Test-Path reports a file that is plainly there as missing. Same
# family of trap as the argument quoting below.
if (-not $Love -or -not (Test-Path -LiteralPath $Love)) {
    throw "love.exe not found. Pass -Love <path> or set the LOVE_EXE environment variable."
}
if (-not (Test-Path -LiteralPath $Rom)) {
    throw "ROM not found: $Rom"
}
if (-not $Report) {
    $Report = Join-Path ([System.IO.Path]::GetTempPath()) 'gen2recomp-test.txt'
}
if (Test-Path -LiteralPath $Report) { Remove-Item -LiteralPath $Report }

$quoted = @(
    ('"{0}"' -f $projectRoot),
    '--test',
    ('"{0}"' -f $Rom),
    ('"{0}"' -f $Report)
)

if ($Other) {
    if (-not (Test-Path -LiteralPath $Other)) {
        throw "second cartridge not found: $Other"
    }
    $quoted += ('"{0}"' -f $Other)
}

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
