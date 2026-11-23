# Installs povy on Windows, in PowerShell 7: Git and mise through winget when they
# are missing, the engine in %LOCALAPPDATA%\povy\engine, and the povy command.
#
#   irm https://raw.githubusercontent.com/Yodatek/povy/main/bootstrap.ps1 | iex
#
# All the code sits in functions and the last line calls them: a truncated download
# runs nothing. macOS, Linux and WSL2 use the bootstrap script instead.
#
# Test seams, never set in normal use: POVY_REPO and POVY_BRANCH pick the engine to
# clone, POVY_USER_PATH_FILE keeps the user PATH in a file instead of the registry,
# and POVY_BOOTSTRAP_NO_INIT skips the offer to configure the machine.

function Write-PovyBootstrapInfo([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Update-PovyBootstrapSessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Install-PovyBootstrapTool([string]$Command, [string]$Id) {
    if (Get-Command $Command -CommandType Application -ErrorAction Ignore) { return }
    if (-not (Get-Command winget -CommandType Application -ErrorAction Ignore)) {
        throw "$Command is missing and winget is not available to install it; install $Id, then run this again"
    }
    Write-PovyBootstrapInfo "Installing $Id with winget"
    winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "could not install $Id with winget" }
    Update-PovyBootstrapSessionPath
    if (-not (Get-Command $Command -CommandType Application -ErrorAction Ignore)) {
        throw "$Id is installed, but $Command is not on PATH yet; open a new terminal and run this again"
    }
}

# Puts the directory of the povy command first in the user PATH, kept unexpanded in
# the registry, then tells running programs.
function Add-PovyBootstrapUserPath([string]$Dir) {
    $entry = '%LOCALAPPDATA%' + $Dir.Substring($env:LOCALAPPDATA.TrimEnd('\').Length)
    if ($env:POVY_USER_PATH_FILE) {
        $raw = if (Test-Path -LiteralPath $env:POVY_USER_PATH_FILE) { ([System.IO.File]::ReadAllText($env:POVY_USER_PATH_FILE)).Trim() } else { '' }
    } else {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
        try {
            $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } finally {
            $key.Dispose()
        }
    }
    $entries = @($raw -split ';' | Where-Object { $_ })
    $present = $entries | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -eq $Dir.TrimEnd('\') }
    if (-not $present) {
        $value = (@($entry) + $entries) -join ';'
        if ($env:POVY_USER_PATH_FILE) {
            [System.IO.File]::WriteAllText($env:POVY_USER_PATH_FILE, $value)
        } else {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
            try {
                $key.SetValue('Path', $value, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            } finally {
                $key.Dispose()
            }
            # Setting any user variable makes .NET broadcast the change to running programs.
            [Environment]::SetEnvironmentVariable('POVY_BOOTSTRAP', '1', 'User')
            [Environment]::SetEnvironmentVariable('POVY_BOOTSTRAP', $null, 'User')
        }
    }
    if (-not (($env:Path -split ';') -contains $Dir)) { $env:Path = "$Dir;$env:Path" }
}

function Install-PovyBootstrap {
    $ErrorActionPreference = 'Stop'
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw 'povy needs PowerShell 7: run "winget install --id Microsoft.PowerShell --exact", then run this again in pwsh'
    }
    if (-not $IsWindows) {
        throw 'this bootstrap is for Windows; on macOS, Linux and WSL2 run: curl -fsSL https://raw.githubusercontent.com/Yodatek/povy/main/bootstrap | bash'
    }
    $repo = if ($env:POVY_REPO) { $env:POVY_REPO } else { 'https://github.com/Yodatek/povy.git' }
    $branch = if ($env:POVY_BRANCH) { $env:POVY_BRANCH } else { 'main' }

    Install-PovyBootstrapTool git Git.Git
    Install-PovyBootstrapTool mise jdx.mise

    $data = Join-Path $env:LOCALAPPDATA 'povy'
    $engine = Join-Path $data 'engine'
    if (Test-Path -LiteralPath (Join-Path $engine '.git')) {
        Write-PovyBootstrapInfo "Updating $engine"
        git -C $engine pull --quiet --ff-only
        if ($LASTEXITCODE -ne 0) { throw "could not update $engine" }
    } elseif (Test-Path -LiteralPath $engine) {
        throw "$engine exists and is not a Git clone; move it away and run this again"
    } else {
        Write-PovyBootstrapInfo "Cloning povy into $engine"
        git clone --quiet --branch $branch -- $repo $engine
        if ($LASTEXITCODE -ne 0) { throw "could not clone $repo" }
    }

    $bin = Join-Path $data 'bin'
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $launcher = Join-Path $bin 'povy.cmd'
    [System.IO.File]::WriteAllText($launcher, "@echo off`r`npwsh -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\engine\bin\povy.ps1`" %*`r`n")
    Add-PovyBootstrapUserPath $bin
    Write-PovyBootstrapInfo "Installed $launcher"

    $configBase = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $env:USERPROFILE '.config' }
    $config = Join-Path $configBase 'povy\config.toml'
    if (-not (Test-Path -LiteralPath $config) -and -not $env:POVY_BOOTSTRAP_NO_INIT -and -not [Console]::IsInputRedirected) {
        $answer = Read-Host -Prompt 'Configure this machine now? [Y/n]'
        if (-not $answer -or $answer -match '^[Yy]') {
            & $launcher init
            if ($LASTEXITCODE -eq 0) { & $launcher apply }
            return
        }
    }
    Write-PovyBootstrapInfo 'Next: povy init, then povy apply'
}

Install-PovyBootstrap
