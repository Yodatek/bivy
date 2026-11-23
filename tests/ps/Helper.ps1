# Shared by the Pester tests of the PowerShell engine. Each test gets its own home,
# user PATH file and PowerShell profile, so the real ones are never touched. Tools
# that mise downloads are shared between tests, in .cache/test-mise.

$script:PovyRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:Pwsh = (Get-Process -Id $PID).Path
$script:SharedMise = [System.IO.Path]::GetFullPath($(if ($env:POVY_TEST_MISE_DATA) { $env:POVY_TEST_MISE_DATA } else { Join-Path $script:PovyRoot '.cache/test-mise' }))
# The sandbox also clears every variable that starts with MISE_, XDG_ or POVY_, as
# the bats tests do. The secrets of the test profiles must come from .env alone.
$script:SandboxVars = @(
    'HOME', 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'EDITOR', 'GIT_CONFIG_NOSYSTEM',
    'EXAMPLE_API_TOKEN', 'SAMPLE_API_TOKEN'
)
$script:SandboxPrefix = '^(MISE|XDG|POVY)_'
# What PowerShell, Git and mise keep for themselves in the home: their caches, and
# the Git directory of the profile clone, which a sync fetches into.
$script:HomeNoise = '^(\.cache|\.local/state/mise|\.local/share/mise|AppData/Local/mise|AppData/(Local|Roaming)/Microsoft)/|(^|/)\.git/'

function Get-PovyPrefixedVar {
    return @(Get-ChildItem -Path Env: | Where-Object { $_.Name -match $script:SandboxPrefix } | ForEach-Object { $_.Name })
}

# Points every location povy uses at a new directory, and returns its paths, with
# those of povy's own files as Initialize-PovyPath sets them there.
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
        Shims = [System.IO.Path]::GetFullPath((Join-Path $script:SharedMise 'data/shims'))
        Saved = @{}
    }
    $sandbox.Data = & $full $(if ($IsWindows) { 'home/AppData/Local/povy' } else { 'home/.local/share/povy' })
    $sandbox.State = & $full $(if ($IsWindows) { 'home/AppData/Local/povy/state' } else { 'home/.local/state/povy' })
    $sandbox.Clone = Join-Path $sandbox.State 'profile'
    $sandbox.Launcher = Join-Path $sandbox.Data 'bin'
    $sandbox.EnvFile = & $full 'home/.config/povy/.env'
    New-Item -ItemType Directory -Force -Path $sandbox.Home, $sandbox.Local, $sandbox.Roaming | Out-Null
    foreach ($name in @($script:SandboxVars) + (Get-PovyPrefixedVar) | Select-Object -Unique) {
        $sandbox.Saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
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
    foreach ($name in Get-PovyPrefixedVar) { [Environment]::SetEnvironmentVariable($name, $null) }
    foreach ($name in $Sandbox.Saved.Keys) { [Environment]::SetEnvironmentVariable($name, $Sandbox.Saved[$name]) }
    Remove-Item -LiteralPath $Sandbox.Root -Recurse -Force -ErrorAction Ignore
}

# Runs povy in a new pwsh, as a user would, and returns its exit code and output.
function Invoke-PovyCli {
    $output = & $script:Pwsh -NoProfile -File (Join-Path $script:PovyRoot 'bin/povy.ps1') @args 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = (@($output) -join "`n") }
}

# The error that a script block stops with. The test fails when the block runs through.
function Get-PovyError([scriptblock]$Block) {
    try {
        $null = & $Block
    } catch {
        return $_.Exception
    }
    throw 'expected an error, but the block ran through'
}

# Every file of the home with its content and time, apart from the noise above: a
# list that changes when anything is written in the home.
function Get-PovyHomeState($Sandbox) {
    $homeDir = $Sandbox.Home
    return @(Get-ChildItem -LiteralPath $homeDir -Recurse -Force -File | ForEach-Object {
            $relative = $_.FullName.Substring($homeDir.Length + 1).Replace('\', '/')
            if ($relative -notmatch $script:HomeNoise) {
                '{0} {1} {2}' -f $relative, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.LastWriteTimeUtc.Ticks
            }
        } | Sort-Object)
}

# Whether only the owner can read a file: mode 600, or on Windows, an access list
# that holds the current user alone and inherits nothing.
function Test-PovyOwnerOnly([string]$Path) {
    if (-not $IsWindows) {
        return [System.IO.File]::GetUnixFileMode($Path) -eq [System.IO.UnixFileMode]'UserRead, UserWrite'
    }
    $acl = Get-Acl -LiteralPath $Path
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    $others = @($rules | Where-Object { $_.IdentityReference -ne $user })
    return ($acl.AreAccessRulesProtected -and $rules.Count -gt 0 -and $others.Count -eq 0)
}

# A bare repository whose main branch is the commit under test. Bare, because Git
# refuses to fetch into the checked-out branch, which main is when Git defaults to it;
# --update-shallow, because CI checks out one commit, and Git otherwise skips the
# branch with a mere warning.
function New-PovySourceRepo([string]$Dest) {
    git init --quiet --bare $Dest
    git -C $Dest fetch --quiet --update-shallow $script:PovyRoot "$(git -C $script:PovyRoot rev-parse HEAD):refs/heads/main"
    git -C $Dest rev-parse --verify --quiet refs/heads/main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not fetch the commit under test into $Dest" }
    git -C $Dest symbolic-ref HEAD refs/heads/main
}

# Commits everything in Dir, on main when the repository is new.
function Initialize-PovyGitRepo([string]$Dir) {
    git -C $Dir init --quiet -b main 2>$null
    Add-PovyGitCommit $Dir
}

# Commits everything in the repository.
function Add-PovyGitCommit([string]$Dir) {
    git -C $Dir add -A
    git -C $Dir -c user.name=t -c user.email=t@example.org commit --quiet -m test
}

# Turns the test profile, or the given directory, into a Git repository.
function New-PovyProfileRepo([string]$Dest, [string]$From = (Join-Path $script:PovyRoot 'tests/fixtures/profile')) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Copy-Item -Path (Join-Path $From '*') -Destination $Dest -Recurse -Force
    Initialize-PovyGitRepo $Dest
}

function Write-PovyTestFile([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Text + "`n")
}

# A profile repository from the bodies of team.toml and mise.toml, each written only
# when given, and other files given as relative path = content.
function New-PovyCustomProfile {
    param(
        [Parameter(Mandatory)][string]$Dest,
        [string]$Team,
        [string]$Project,
        [hashtable]$Files = @{}
    )
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    if ($PSBoundParameters.ContainsKey('Team')) { Write-PovyTestFile (Join-Path $Dest 'team.toml') $Team }
    if ($PSBoundParameters.ContainsKey('Project')) { Write-PovyTestFile (Join-Path $Dest 'mise.toml') $Project }
    foreach ($name in $Files.Keys) { Write-PovyTestFile (Join-Path $Dest $name) $Files[$name] }
    Initialize-PovyGitRepo $Dest
}

function Write-PovyTestConfig([string]$File, [string]$ProfileUrl = '', [string]$Extra = '') {
    $url = $ProfileUrl.Replace('\', '/')
    [System.IO.File]::WriteAllText($File, "name = `"Test User`"`nemail = `"test@example.org`"`nprofile = `"$url`"`n$Extra`n")
}
