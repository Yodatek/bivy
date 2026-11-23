# Shared by the Pester tests of the PowerShell engine. Each test gets its own home,
# user PATH file and PowerShell profile, so the real ones are never touched. Tools
# that mise downloads are shared between tests, in .cache/test-mise.

$script:PovyRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:Pwsh = (Get-Process -Id $PID).Path
$script:SharedMise = [System.IO.Path]::GetFullPath($(if ($env:POVY_TEST_MISE_DATA) { $env:POVY_TEST_MISE_DATA } else { Join-Path $script:PovyRoot '.cache/test-mise' }))
$script:SandboxVars = @(
    'HOME', 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'XDG_DATA_HOME',
    'MISE_DATA_DIR', 'MISE_CACHE_DIR', 'MISE_CONFIG_DIR', 'POVY_USER_PATH_FILE', 'POVY_USER_ENV_KEY',
    'POVY_PS_PROFILE', 'POVY_WINGET', 'POVY_REPO', 'POVY_BRANCH', 'POVY_BOOTSTRAP_NO_INIT', 'EDITOR',
    'GIT_CONFIG_NOSYSTEM'
)

# Points every location povy uses at a new directory, and returns its paths.
function New-PovySandbox {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('povy-test-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 12))
    $full = { param($Relative) [System.IO.Path]::GetFullPath((Join-Path $root $Relative)) }
    $sandbox = [ordered]@{
        Root = [System.IO.Path]::GetFullPath($root)
        Home = & $full 'home'
        # Laid out as a Windows profile: known folders such as the local application
        # data resolve from USERPROFILE, and must exist, or mise cannot verify downloads.
        Local = & $full 'home/AppData/Local'
        Roaming = & $full 'home/AppData/Roaming'
        UserPath = & $full 'user-path'
        PsProfile = & $full 'home/profile.ps1'
        Saved = @{}
    }
    New-Item -ItemType Directory -Force -Path $sandbox.Home, $sandbox.Local, $sandbox.Roaming | Out-Null
    foreach ($name in $script:SandboxVars) { $sandbox.Saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    foreach ($name in $script:SandboxVars) { [Environment]::SetEnvironmentVariable($name, $null) }
    $env:HOME = $sandbox.Home
    if ($IsWindows) {
        $env:USERPROFILE = $sandbox.Home
        $env:LOCALAPPDATA = $sandbox.Local
        $env:APPDATA = $sandbox.Roaming
    }
    $env:MISE_DATA_DIR = Join-Path $script:SharedMise 'data'
    $env:MISE_CACHE_DIR = Join-Path $script:SharedMise 'cache'
    $env:MISE_CONFIG_DIR = Join-Path $sandbox.Home '.config/mise'
    $env:POVY_USER_PATH_FILE = $sandbox.UserPath
    $env:POVY_PS_PROFILE = $sandbox.PsProfile
    $env:GIT_CONFIG_NOSYSTEM = '1'
    return $sandbox
}

function Remove-PovySandbox($Sandbox) {
    foreach ($name in $script:SandboxVars) { [Environment]::SetEnvironmentVariable($name, $Sandbox.Saved[$name]) }
    Remove-Item -LiteralPath $Sandbox.Root -Recurse -Force -ErrorAction Ignore
}

# Runs povy in a new pwsh, as a user would, and returns its exit code and output.
function Invoke-PovyCli {
    $output = & $script:Pwsh -NoProfile -File (Join-Path $script:PovyRoot 'bin/povy.ps1') @args 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = (@($output) -join "`n") }
}

# A bare repository whose main branch is the commit under test. Bare, because Git
# refuses to fetch into the checked-out branch, which main is when Git defaults to it.
function New-PovySourceRepo([string]$Dest) {
    git init --quiet --bare $Dest
    git -C $Dest fetch --quiet $script:PovyRoot "$(git -C $script:PovyRoot rev-parse HEAD):refs/heads/main"
    if ($LASTEXITCODE -ne 0) { throw "could not fetch the commit under test into $Dest" }
    git -C $Dest symbolic-ref HEAD refs/heads/main
}

function Initialize-PovyGitRepo([string]$Dir) {
    git -C $Dir init --quiet -b main 2>$null
    git -C $Dir add -A
    git -C $Dir -c user.name=t -c user.email=t@example.org commit --quiet -m test
}

# Turns the test profile, or the given directory, into a Git repository.
function New-PovyProfileRepo([string]$Dest, [string]$From = (Join-Path $script:PovyRoot 'tests/fixtures/profile')) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Copy-Item -Path (Join-Path $From '*') -Destination $Dest -Recurse -Force
    Initialize-PovyGitRepo $Dest
}

# A profile from a profile.toml body, and templates given as name = content.
function New-PovyCustomProfile([string]$Dest, [string]$Toml, [hashtable]$Templates = @{}) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Dest 'files') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Dest 'profile.toml'), $Toml + "`n")
    foreach ($name in $Templates.Keys) {
        [System.IO.File]::WriteAllText((Join-Path $Dest "files/$name"), $Templates[$name] + "`n")
    }
    Initialize-PovyGitRepo $Dest
}

function Write-PovyTestConfig([string]$File, [string]$ProfileUrl = '', [string]$Extra = '') {
    $url = $ProfileUrl.Replace('\', '/')
    [System.IO.File]::WriteAllText($File, "name = `"Test User`"`nemail = `"test@example.org`"`nprofile = `"$url`"`n$Extra`n")
}
