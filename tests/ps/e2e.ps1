#Requires -Version 7.2
# End-to-end run of povy on a real Windows, for CI: the bootstrap as irm | iex runs
# it, then init, apply and doctor with the sample profile, without any test seam.
# It changes the user PATH, the PowerShell profile and the Git config of the machine,
# so it refuses to run anywhere but in CI.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '',
    Justification = 'The bootstrap is meant to run through Invoke-Expression, as irm | iex does')]
param()
$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true' -or -not $IsWindows) {
    throw 'this end-to-end run changes the machine: it only runs in CI, on Windows'
}

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$work = Join-Path ([System.IO.Path]::GetTempPath()) 'povy-e2e'
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Ignore
New-Item -ItemType Directory -Path $work | Out-Null

function Assert-E2e([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "e2e: $Message" }
}

# The log goes straight to the console: what a function writes to its output stream
# becomes its return value.
function Write-E2eLog([string]$Text) {
    [Console]::Out.WriteLine($Text)
}

# Runs a step in a collapsible group of the CI log, and returns what it printed.
function Invoke-E2eStep([string]$Title, [scriptblock]$Block) {
    Write-E2eLog "::group::$Title"
    $output = & $Block 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-E2eLog $output
    Write-E2eLog '::endgroup::'
    Assert-E2e ($code -eq 0) "$Title failed with exit code $code"
    return $output
}

# A repository with a main branch at the commit under test, for the engine and the
# profile alike.
$source = Join-Path $work 'source'
git init --quiet $source
git -C $source fetch --quiet $root "$(git -C $root rev-parse HEAD):refs/heads/main"
git -C $source symbolic-ref HEAD refs/heads/main

Write-E2eLog '::group::bootstrap.ps1, through Invoke-Expression'
$env:POVY_REPO = $source
$env:POVY_BOOTSTRAP_NO_INIT = '1'
Invoke-Expression (Get-Content -Raw -LiteralPath (Join-Path $root 'bootstrap.ps1'))
Write-E2eLog '::endgroup::'
$povy = Join-Path $env:LOCALAPPDATA 'povy\bin\povy.cmd'
Assert-E2e (Test-Path -LiteralPath $povy) 'the bootstrap did not install povy.cmd'

$config = Join-Path $work 'config.toml'
Set-Content -LiteralPath $config -Value @"
name = "Ada Lovelace"
email = "ada@example.org"
profile = "$($source.Replace('\', '/'))"
profile_path = "_samples/profile"
"@
Invoke-E2eStep 'povy init' { & $povy init --config $config } | Out-Null
Add-Content -LiteralPath (Join-Path $HOME '.config\povy\.env') -Value 'SAMPLE_API_TOKEN=e2e'

Invoke-E2eStep 'povy apply' { & $povy apply } | Out-Null
$again = Invoke-E2eStep 'povy apply, again' { & $povy apply }
Assert-E2e ($again -match 'Applied: 0 written') 'the second apply changed something'
Invoke-E2eStep 'povy doctor' { & $povy doctor } | Out-Null

# A new PowerShell session, which loads the profile.
$session = Invoke-E2eStep 'a new PowerShell session' {
    pwsh -Command 'sample-hello e2e; (Get-Command ll).CommandType; jq --version; node --version; prettier --version; git config --global user.email'
}
foreach ($expected in 'hello from the sample profile, e2e', 'Function', 'jq-1.7.1', 'v22.', 'ada@example.org') {
    Assert-E2e ($session.Contains($expected)) "the new session lacks: $expected"
}

# A new process outside PowerShell, with the PATH Windows gives it: the system one,
# then the user one that povy set. starship comes from the mise shims only.
$saved = $env:Path
try {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $cmd = Invoke-E2eStep 'a new cmd.exe process' { cmd /c 'starship --version' }
} finally {
    $env:Path = $saved
}
Assert-E2e ($cmd.Contains('starship 1.27.0')) 'cmd.exe does not see starship from the mise shims'

Write-E2eLog 'e2e: all good'
