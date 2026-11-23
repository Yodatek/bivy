#Requires -Version 7.2
# End-to-end run of povy on a real Windows, for CI: the bootstrap as irm | iex runs
# it, then init, apply and doctor with the sample profile, without any test seam.
# It changes the user PATH, the PowerShell profile and the Git config of the machine,
# and installs the tools of the sample with mise, so it refuses to run anywhere but
# in CI. The sample installs no package on Windows: its [bootstrap.packages] only
# lists brew, apt and dnf.
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

# Whether only the current user can read a file, with nothing inherited.
function Test-E2eOwnerOnly([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    $others = @($rules | Where-Object { $_.IdentityReference -ne $user })
    return ($acl.AreAccessRulesProtected -and $rules.Count -gt 0 -and $others.Count -eq 0)
}

# A bare repository whose main branch is the commit under test, for the engine and
# the profile alike. Bare, because Git refuses to fetch into the checked-out branch;
# --update-shallow, because CI checks out one commit, and Git otherwise skips the
# branch with a mere warning.
$source = Join-Path $work 'source.git'
git init --quiet --bare $source
git -C $source fetch --quiet --update-shallow $root "$(git -C $root rev-parse HEAD):refs/heads/main"
git -C $source rev-parse --verify --quiet refs/heads/main | Out-Null
Assert-E2e ($LASTEXITCODE -eq 0) 'could not fetch the commit under test'
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

# mise writes no file on Windows: povy writes those of [_.povy.windows], the template
# with the secret of .env, for the owner alone.
$sampleConf = Join-Path $HOME '.config\povy-sample\sample.conf'
Assert-E2e (Test-Path -LiteralPath $sampleConf) 'povy did not write sample.conf'
Assert-E2e (@(Get-Content -LiteralPath $sampleConf) -contains 'token = e2e') 'sample.conf lacks the secret of .env'
Assert-E2e (Test-E2eOwnerOnly $sampleConf) 'sample.conf is readable by others'
$starshipConf = Join-Path $HOME '.config\starship.toml'
Assert-E2e (Test-Path -LiteralPath $starshipConf) 'povy did not write starship.toml'
Assert-E2e (@(Get-Content -LiteralPath $starshipConf) -contains 'add_newline = false') 'starship.toml is not the one of the sample'

# New processes run from the work directory: in the povy checkout, its mise.toml
# would install the development tools of povy. The PowerShell is this one, not a
# shim. Git only follows the include of the identity with --includes, since
# --global reads one file.
$pwsh = (Get-Process -Id $PID).Path
$sampleRoot = Join-Path $env:LOCALAPPDATA 'povy\state\profile\_samples\profile'
$sampleHello = Join-Path $sampleRoot 'bin\sample-hello.ps1'
$aliases = Join-Path $sampleRoot 'shell\aliases.ps1'
Push-Location -LiteralPath $work
try {
    # A new PowerShell session, which loads the profile.
    $session = Invoke-E2eStep 'a new PowerShell session' {
        & $pwsh -Command 'sample-hello e2e; (Get-Command sample-hello).Source; (Get-Command ll).CommandType; (Get-Command ll).ScriptBlock.File; jq --version; node --version; prettier --version; git config --global --includes user.email'
    }
    foreach ($expected in 'hello from the sample profile, e2e', $sampleHello, 'Function', $aliases, 'jq-1.7.1', 'v22.', 'ada@example.org') {
        Assert-E2e ($session.Contains($expected)) "the new session lacks: $expected"
    }
    Assert-E2e ($session -match '(?m)^3\.\d+\.\d+\s*$') 'the new session lacks prettier 3'

    # A new process outside PowerShell, with the PATH Windows gives it: the system
    # one, then the user one that povy set. starship comes from the mise shims only.
    $saved = $env:Path
    try {
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
        $cmd = Invoke-E2eStep 'a new cmd.exe process' { cmd /c 'starship --version' }
    } finally {
        $env:Path = $saved
    }
    Assert-E2e ($cmd.Contains('starship 1.27.0')) 'cmd.exe does not see starship from the mise shims'
} finally {
    Pop-Location
}

Write-E2eLog 'e2e: all good'
