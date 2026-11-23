# Shared helpers of the PowerShell engine: messages, paths, private files, marked
# blocks, mise and TOML. The engine targets Windows; its tests also run it on macOS
# and Linux, where the Windows-only parts go through test seams.

$script:PovyYqTool = 'yq@4'
$script:PovyYq = $null
$script:PovyWritten = 0
$script:PovyUnchanged = 0
$script:PovyBackedUp = 0
$script:PovyBackupDir = $null
# Files this run created: they have no original to back up.
$script:PovyCreated = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:PovyUtf8 = [System.Text.UTF8Encoding]::new($false)

function Write-PovyInfo([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Write-PovyWarning([string]$Message) {
    [Console]::Error.WriteLine("warning: $Message")
}

# Errors meant for the user carry a marker, so that bin/povy.ps1 prints them alone.
function Stop-Povy([string]$Message) {
    $exception = [System.Exception]::new($Message)
    $exception.Data['povy'] = $true
    throw $exception
}

function Test-PovyControlChar([string]$Value) {
    return $Value -match '[\x00-\x1f\x7f]'
}

function Get-PovyHome {
    $path = if ($IsWindows) { $env:USERPROFILE } else { $env:HOME }
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) {
        Stop-Povy 'the home directory is not set to an existing directory'
    }
    return [System.IO.Path]::GetFullPath($path).TrimEnd('\', '/')
}

function Initialize-PovyPath {
    $script:PovyHome = Get-PovyHome
    $configBase = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $script:PovyHome '.config' }
    $script:PovyConfigDir = Join-Path $configBase 'povy'
    $script:PovyConfigFile = Join-Path $script:PovyConfigDir 'config.toml'
    $script:PovyEnvFile = Join-Path $script:PovyConfigDir '.env'
    $script:PovyInteractive = Join-Path $script:PovyConfigDir 'interactive.ps1'
    $script:PovyGitDir = Join-Path $script:PovyConfigDir 'git'
    if ($IsWindows) {
        if (-not $env:LOCALAPPDATA) { Stop-Povy 'LOCALAPPDATA is not set' }
        $script:PovyDataDir = Join-Path $env:LOCALAPPDATA 'povy'
        $script:PovyStateDir = Join-Path $script:PovyDataDir 'state'
        $miseData = if ($env:MISE_DATA_DIR) { $env:MISE_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'mise' }
    } else {
        $dataBase = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $script:PovyHome '.local/share' }
        $stateBase = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { Join-Path $script:PovyHome '.local/state' }
        $script:PovyDataDir = Join-Path $dataBase 'povy'
        $script:PovyStateDir = Join-Path $stateBase 'povy'
        $miseData = if ($env:MISE_DATA_DIR) { $env:MISE_DATA_DIR } else { Join-Path $dataBase 'mise' }
    }
    $miseConfig = if ($env:MISE_CONFIG_DIR) { $env:MISE_CONFIG_DIR } else { Join-Path $configBase 'mise' }
    $script:PovyMiseConf = Join-Path $miseConfig 'conf.d/povy.toml'
    $script:PovyShimsDir = Join-Path $miseData 'shims'
    $script:PovyLauncherDir = Join-Path $script:PovyDataDir 'bin'
    $script:PovyProfileDir = Join-Path $script:PovyStateDir 'profile'
    $script:PovyProfileRoot = $script:PovyProfileDir
    $script:PovyBackupRoot = Join-Path $script:PovyStateDir 'backups'
    $script:PovyPsProfile = if ($env:POVY_PS_PROFILE) { $env:POVY_PS_PROFILE } else { $PROFILE.CurrentUserAllHosts }
}

function Initialize-PovyDirectory {
    foreach ($dir in $script:PovyConfigDir, $script:PovyStateDir) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Set-PovyPrivate $dir
        }
    }
}

# A path as a person reads it, with ~ for the home directory.
function Format-PovyPath([string]$Path) {
    $homeDir = $script:PovyHome
    if ($Path.StartsWith($homeDir + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        return '~' + $Path.Substring($homeDir.Length)
    }
    return $Path
}

# Files with secrets get the equivalent of mode 600: on Windows, an access list that
# only lets the current user in, with nothing inherited.
function Set-PovyPrivate([string]$Path) {
    $isDir = Test-Path -LiteralPath $Path -PathType Container
    if ($IsWindows) {
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        if ($isDir) {
            $acl = [System.Security.AccessControl.DirectorySecurity]::new()
            $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        } else {
            $acl = [System.Security.AccessControl.FileSecurity]::new()
            $inherit = [System.Security.AccessControl.InheritanceFlags]::None
        }
        $acl.SetAccessRuleProtection($true, $false)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($user, 'FullControl', $inherit,
            [System.Security.AccessControl.PropagationFlags]::None, 'Allow')
        $acl.AddAccessRule($rule)
        if ($isDir) {
            [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new($Path), $acl)
        } else {
            [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.FileInfo]::new($Path), $acl)
        }
    } else {
        $mode = if ($isDir) { 'UserRead, UserWrite, UserExecute' } else { 'UserRead, UserWrite' }
        [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]$mode)
    }
}

function Test-PovyPrivate([string]$Path) {
    if ($IsWindows) {
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.FileInfo]::new($Path))
        if (-not $acl.AreAccessRulesProtected) { return $false }
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        $others = @($rules | Where-Object { $_.IdentityReference.Value -ne $user.Value })
        return ($rules.Count -gt 0 -and $others.Count -eq 0)
    }
    return ([System.IO.File]::GetUnixFileMode($Path) -eq [System.IO.UnixFileMode]'UserRead, UserWrite')
}

function Backup-PovyFile([string]$Path) {
    if ($script:PovyCreated.Contains($Path)) { return }
    if (-not $script:PovyBackupDir) {
        $script:PovyBackupDir = Join-Path $script:PovyBackupRoot ('{0}.{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID)
    }
    $homeDir = $script:PovyHome
    if ($Path.StartsWith($homeDir + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $Path.Substring($homeDir.Length + 1)
    } else {
        $relative = $Path.Substring([System.IO.Path]::GetPathRoot($Path).Length)
    }
    $dest = Join-Path $script:PovyBackupDir $relative
    # A file changed twice in one run keeps its first copy: the original.
    if (Test-Path -LiteralPath $dest) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Copy-Item -LiteralPath $Path -Destination $dest -Force
    Set-PovyPrivate $dest
    $script:PovyBackedUp++
    Write-PovyInfo "backed up $Path"
}

function Test-PovySameContent([string]$Left, [string]$Right) {
    $a = [System.IO.File]::ReadAllBytes($Left)
    $b = [System.IO.File]::ReadAllBytes($Right)
    return [System.Linq.Enumerable]::SequenceEqual($a, $b)
}

# Installs Source at Target in one move. An identical file is left alone, apart from
# its access list; anything else that would be replaced is backed up first.
function Install-PovyFile([string]$Source, [string]$Target, [switch]$Private) {
    if (Test-Path -LiteralPath $Target -PathType Container) {
        Stop-Povy "$Target is a directory, refusing to replace it"
    }
    $item = Get-Item -LiteralPath $Target -Force -ErrorAction Ignore
    if ($item -and -not $item.LinkType -and (Test-PovySameContent $Source $Target)) {
        if ($Private -and -not (Test-PovyPrivate $Target)) { Set-PovyPrivate $Target }
        $script:PovyUnchanged++
        return
    }
    if ($item) { Backup-PovyFile $Target } else { [void]$script:PovyCreated.Add($Target) }
    $parent = Split-Path -Parent $Target
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $tmp = Join-Path $parent ('.povy.' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        [System.IO.File]::WriteAllBytes($tmp, [System.IO.File]::ReadAllBytes($Source))
        if ($Private) { Set-PovyPrivate $tmp }
        if ($item -and $item.LinkType) { Remove-Item -LiteralPath $Target -Force }
        [System.IO.File]::Move($tmp, $Target, $true)
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction Ignore
        Stop-Povy "cannot write ${Target}: $($_.Exception.Message)"
    }
    $script:PovyWritten++
    Write-PovyInfo "wrote $Target"
}

# Writes text to a new private temporary file and returns its path.
function New-PovyStagedFile([string]$Text) {
    $path = Join-Path $script:PovyStateDir ('staged.' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    [System.IO.File]::WriteAllText($path, $Text, $script:PovyUtf8)
    Set-PovyPrivate $path
    return $path
}

function Get-PovyBlockMarker([string]$Name, [switch]$End) {
    $label = if ($Name) { "povy $Name" } else { 'povy' }
    if ($End) { return "# <<< $label <<<" }
    return "# >>> $label >>>"
}

# Puts a marked block at the top or at the bottom of a file, keeping its encoding and
# line endings. At the top, a block already there is refreshed in place. At the
# bottom, it moves to the end, after whatever the file sets before it. Content
# outside the block is not touched.
function Set-PovyBlock {
    param(
        [string]$File,
        [string]$Block,
        [ValidateSet('top', 'bottom')][string]$Position = 'top',
        [string]$Name = ''
    )
    $start = Get-PovyBlockMarker $Name
    $end = Get-PovyBlockMarker $Name -End
    $blockLines = @($Block -split "`r?`n")
    if (-not (Test-Path -LiteralPath $File)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $File) | Out-Null
        [System.IO.File]::WriteAllText($File, ($blockLines -join [Environment]::NewLine) + [Environment]::NewLine, $script:PovyUtf8)
        [void]$script:PovyCreated.Add($File)
        $script:PovyWritten++
        Write-PovyInfo "wrote $File"
        return
    }

    $reader = [System.IO.StreamReader]::new($File, $script:PovyUtf8, $true)
    try {
        $text = $reader.ReadToEnd()
        $encoding = $reader.CurrentEncoding
    } finally {
        $reader.Dispose()
    }
    $newline = if ($text.Contains("`r`n")) { "`r`n" } elseif ($text.Contains("`n")) { "`n" } else { [Environment]::NewLine }
    $finalNewline = $text.EndsWith("`n")
    $body = if ($finalNewline) { $text.Substring(0, $text.Length - 1).TrimEnd("`r") } else { $text }
    # @() around if: an if statement unrolls a one-element array into its element.
    $lines = @(if ($body.Length -gt 0) { $body -split "`r?`n" })

    $starts = @($lines | Where-Object { $_ -ceq $start }).Count
    $ends = @($lines | Where-Object { $_ -ceq $end }).Count
    if ($starts -ne $ends -or $starts -gt 1) {
        Stop-Povy "$File has an incomplete povy block; remove its markers and run povy apply again"
    }
    $first = [Array]::IndexOf($lines, $start)
    $last = [Array]::IndexOf($lines, $end)

    if ($Position -eq 'bottom') {
        if ($starts -eq 0) {
            $kept = $lines
        } else {
            $before = @(if ($first -gt 0) { $lines[0..($first - 1)] })
            $kept = $before + @($lines | Select-Object -Skip ($last + 1))
        }
        $new = @($kept) + $blockLines
        $finalNewline = $true
    } elseif ($starts -eq 0) {
        $new = $blockLines + $lines
    } else {
        $current = $lines[$first..$last]
        if (($current -join "`n") -ceq ($blockLines -join "`n")) {
            $script:PovyUnchanged++
            return
        }
        $before = @(if ($first -gt 0) { $lines[0..($first - 1)] })
        $new = @($before) + $blockLines + @($lines | Select-Object -Skip ($last + 1))
    }
    $newText = ($new -join $newline) + $(if ($finalNewline) { $newline } else { '' })
    if ($newText -ceq $text) {
        $script:PovyUnchanged++
        return
    }
    Backup-PovyFile $File
    [System.IO.File]::WriteAllText($File, $newText, $encoding)
    $script:PovyWritten++
    Write-PovyInfo "updated $File"
}

function Get-PovyMise {
    $command = Get-Command mise -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

# Runs mise from the home directory, so that the project config of the current
# directory plays no part, with its colours off for parsing.
function Invoke-PovyMise {
    $mise = Get-PovyMise
    if (-not $mise) { Stop-Povy 'mise is not installed; run the povy bootstrap first' }
    $previous = $env:NO_COLOR
    $env:NO_COLOR = '1'
    Push-Location -LiteralPath $script:PovyHome
    try {
        & $mise @args
    } finally {
        Pop-Location
        $env:NO_COLOR = $previous
    }
}

function Get-PovyYq {
    if ($script:PovyYq) { return $script:PovyYq }
    $path = Invoke-PovyMise which yq --tool $script:PovyYqTool 2>$null
    if ($LASTEXITCODE -eq 0 -and $path) {
        $script:PovyYq = ([string]$path).Trim()
        return $script:PovyYq
    }
    return $null
}

function Install-PovyYq {
    if (Get-PovyYq) { return }
    Write-PovyInfo "installing $script:PovyYqTool with mise"
    Invoke-PovyMise install $script:PovyYqTool | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Get-PovyYq)) { Stop-Povy "could not install $script:PovyYqTool with mise" }
}

# Reads a TOML file into ordered hashtables, through yq.
function Read-PovyToml([string]$File) {
    $yq = Get-PovyYq
    if (-not $yq) { Stop-Povy "$script:PovyYqTool is not installed; run: povy init" }
    $json = & $yq -p toml -o json $File 2>$null
    if ($LASTEXITCODE -ne 0) { Stop-Povy "$File is not valid TOML" }
    $text = ($json -join "`n").Trim()
    if (-not $text -or $text -eq 'null') { return [ordered]@{} }
    return ($text | ConvertFrom-Json -AsHashtable -Depth 64)
}
