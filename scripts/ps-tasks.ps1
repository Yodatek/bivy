#!/usr/bin/env pwsh
# Tests and lint of the PowerShell engine, for mise run test-ps and mise run lint-ps,
# and for CI. Pester and PSScriptAnalyzer are saved in .cache/ps-modules, not installed.
param([Parameter(Mandatory)][ValidateSet('test', 'lint')][string]$Task)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$modules = Join-Path $root '.cache/ps-modules'
$wanted = @{ Pester = '[5.7,6.0)'; PSScriptAnalyzer = '[1.24,2.0)' }
foreach ($name in $wanted.Keys) {
    if (-not (Test-Path -LiteralPath (Join-Path $modules $name))) {
        New-Item -ItemType Directory -Force -Path $modules | Out-Null
        Save-PSResource -Name $name -Version $wanted[$name] -Path $modules -TrustRepository -Quiet
    }
}
$env:PSModulePath = $modules + [System.IO.Path]::PathSeparator + $env:PSModulePath

if ($Task -eq 'test') {
    Import-Module Pester -MinimumVersion 5.7
    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $root 'tests/ps'
    $config.Run.Exit = $true
    $config.Output.Verbosity = 'Detailed'
    Invoke-Pester -Configuration $config
} else {
    Import-Module PSScriptAnalyzer
    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    $paths = @('bin/povy.ps1', 'bootstrap.ps1', 'lib/ps', 'scripts/ps-tasks.ps1', 'tests/ps') | ForEach-Object { Join-Path $root $_ }
    $issues = @($paths | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings $settings })
    $issues | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-String -Width 200 | Write-Output
    if ($issues.Count -gt 0) { exit 1 }
}
