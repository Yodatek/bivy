#!/usr/bin/env pwsh
#Requires -Version 7.2
# povy on Windows, in PowerShell 7. The bash engine, bin/povy, serves macOS, Linux and
# WSL2; both read the same config.toml and profile.toml.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$script:PovyRoot = Split-Path -Parent $PSScriptRoot
foreach ($lib in 'common', 'config', 'profile', 'system', 'git', 'commands') {
    . (Join-Path $script:PovyRoot "lib/ps/$lib.ps1")
}

try {
    Invoke-Povy -Arguments $args
    exit $script:PovyExitCode
} catch {
    if ($_.Exception.Data['povy']) {
        [Console]::Error.WriteLine("error: $($_.Exception.Message)")
    } else {
        [Console]::Error.WriteLine("error: $($_.Exception.Message)")
        [Console]::Error.WriteLine($_.ScriptStackTrace)
    }
    exit 1
}
