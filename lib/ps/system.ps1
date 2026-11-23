# What povy changes in Windows itself: the user PATH, which every new process gets,
# graphical apps included, and the PowerShell profile, for interactive sessions.
# Packages are mise bootstrap's, winget included.
#
# Test seams, never set in normal use:
#   POVY_USER_PATH_FILE  keeps the user PATH in a file instead of the registry
#   POVY_USER_ENV_KEY    the registry key under HKCU that holds it, Environment by default
#   POVY_PS_PROFILE      the PowerShell profile to edit

function Get-PovyUserEnvKey {
    if ($env:POVY_USER_ENV_KEY) { return $env:POVY_USER_ENV_KEY }
    return 'Environment'
}

# The user PATH as stored, with %VARIABLES% left unexpanded.
function Get-PovyUserPathValue {
    if ($env:POVY_USER_PATH_FILE) {
        if (-not (Test-Path -LiteralPath $env:POVY_USER_PATH_FILE)) { return '' }
        return ([System.IO.File]::ReadAllText($env:POVY_USER_PATH_FILE)).Trim()
    }
    if (-not $IsWindows) { Stop-Povy 'povy for PowerShell runs on Windows; use bin/povy on macOS, Linux and WSL2' }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey((Get-PovyUserEnvKey))
    if (-not $key) { return '' }
    try {
        return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally {
        $key.Dispose()
    }
}

# Running programs learn about the new PATH from a WM_SETTINGCHANGE broadcast.
function Send-PovySettingChange {
    if (-not ('Povy.NativeMethods' -as [type])) {
        Add-Type -Namespace Povy -Name NativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint msg, System.UIntPtr wParam, string lParam, uint flags, uint timeout, out System.UIntPtr result);
'@
    }
    $result = [System.UIntPtr]::Zero
    [void][Povy.NativeMethods]::SendMessageTimeout([System.IntPtr]0xffff, 0x1A, [System.UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
}

function Set-PovyUserPathValue([string]$Value) {
    if ($env:POVY_USER_PATH_FILE) {
        [System.IO.File]::WriteAllText($env:POVY_USER_PATH_FILE, $Value, $script:PovyUtf8)
        return
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey((Get-PovyUserEnvKey))
    try {
        $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally {
        $key.Dispose()
    }
    Send-PovySettingChange
}

# A directory as a PATH entry: %LOCALAPPDATA% or %USERPROFILE% when it lies below,
# so that the entry stays readable and survives a renamed account.
function ConvertTo-PovyPathEntry([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    foreach ($name in 'LOCALAPPDATA', 'USERPROFILE') {
        $base = [Environment]::GetEnvironmentVariable($name)
        if ($base -and $full.StartsWith($base.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            return "%$name%" + $full.Substring($base.TrimEnd('\', '/').Length)
        }
    }
    return $full
}

function ConvertTo-PovyComparablePath([string]$Entry) {
    $expanded = [Environment]::ExpandEnvironmentVariables($Entry)
    try {
        return [System.IO.Path]::GetFullPath($expanded).TrimEnd('\', '/').ToLowerInvariant()
    } catch {
        return $expanded.TrimEnd('\', '/').ToLowerInvariant()
    }
}

# The directories povy puts on the user PATH, in order: the mise shims, the
# profile's commands, ~/.local/bin, then the povy command itself.
function Get-PovyWantedPath {
    $wanted = [System.Collections.Generic.List[string]]::new()
    $wanted.Add($script:PovyShimsDir)
    if ($script:Prof.Bin) { $wanted.Add($script:Prof.Bin) }
    $wanted.Add($script:PovyLocalBin)
    if (Test-Path -LiteralPath $script:PovyLauncherDir -PathType Container) { $wanted.Add($script:PovyLauncherDir) }
    return $wanted.ToArray()
}

# On Windows, a mise shim is a small program that runs mise itself, so a new process
# needs mise on its PATH too. Returns the directory of mise when the system PATH
# lacks it, and $null otherwise.
function Get-PovyMissingMiseDir {
    if (-not $IsWindows) { return $null }
    $mise = Get-PovyMise
    if (-not $mise) { return $null }
    $dir = Split-Path -Parent $mise
    $key = ConvertTo-PovyComparablePath $dir
    $machine = @([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' | Where-Object { $_ })
    if (@($machine | Where-Object { (ConvertTo-PovyComparablePath $_) -eq $key }).Count -gt 0) { return $null }
    return $dir
}

# Keeps the user PATH as it was before povy changed it, with the other backups of
# the run, since the registry keeps no history.
function Save-PovyUserPath([string]$Raw) {
    if (-not $Raw) { return }
    if (-not $script:PovyBackupDir) {
        $script:PovyBackupDir = Join-Path $script:PovyBackupRoot ('{0}.{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID)
    }
    $dest = Join-Path $script:PovyBackupDir 'user-path.txt'
    if (Test-Path -LiteralPath $dest) { return }
    New-Item -ItemType Directory -Force -Path $script:PovyBackupDir | Out-Null
    [System.IO.File]::WriteAllText($dest, $Raw, $script:PovyUtf8)
    $script:PovyBackedUp++
    Write-PovyInfo "backed up the user PATH to $dest"
}

# Puts the wanted directories first in the user PATH. Entries povy owns, under its
# data directory or the shims, are replaced; every other entry stays as it was. The
# directory of mise, when the shims need it, goes at the end and stays there.
function Update-PovyUserPath {
    $raw = Get-PovyUserPathValue
    $entries = @($raw -split ';' | Where-Object { $_ })
    $wanted = @(Get-PovyWantedPath | ForEach-Object { ConvertTo-PovyPathEntry $_ })
    $owned = (ConvertTo-PovyComparablePath $script:PovyDataDir) + [System.IO.Path]::DirectorySeparatorChar
    $shims = ConvertTo-PovyComparablePath $script:PovyShimsDir
    $wantedKeys = @($wanted | ForEach-Object { ConvertTo-PovyComparablePath $_ })
    $others = @($entries | Where-Object {
            $key = ConvertTo-PovyComparablePath $_
            -not ($key -eq $shims -or ($key + [System.IO.Path]::DirectorySeparatorChar).StartsWith($owned) -or $wantedKeys -contains $key)
        })
    $new = @($wanted) + $others
    $miseDir = Get-PovyMissingMiseDir
    if ($miseDir) {
        $miseKey = ConvertTo-PovyComparablePath $miseDir
        if (@($new | Where-Object { (ConvertTo-PovyComparablePath $_) -eq $miseKey }).Count -eq 0) {
            $new += ConvertTo-PovyPathEntry $miseDir
        }
    }
    $value = $new -join ';'
    if ($value -ceq $raw) {
        $script:PovyUnchanged++
        return
    }
    Save-PovyUserPath $raw
    Set-PovyUserPathValue $value
    $script:PovyWritten++
    Write-PovyInfo "set the user PATH: $($wanted -join ';')"
}

function Test-PovyOnUserPath([string]$Path) {
    $key = ConvertTo-PovyComparablePath $Path
    return [bool](@((Get-PovyUserPathValue) -split ';' | Where-Object { $_ -and (ConvertTo-PovyComparablePath $_) -eq $key }).Count)
}

function ConvertTo-PovyPsLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

# interactive.ps1, which the PowerShell profile sources: the tools first on PATH in
# the session, since Windows puts the system PATH before the user one, then the
# profile's PowerShell files, which can set aliases, functions and the prompt.
function Write-PovyInteractive {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Generated by povy apply. Changes here are overwritten.')
    $lines.Add('if ($global:__povy_loaded) { return }')
    $lines.Add('$global:__povy_loaded = $true')
    $front = @(Get-PovyWantedPath | Where-Object { $_ -ne $script:PovyLauncherDir } | ForEach-Object { ConvertTo-PovyPsLiteral $_ })
    $lines.Add('$__povy_front = @(' + ($front -join ', ') + ')')
    $lines.Add('$env:PATH = (@($__povy_front) + @($env:PATH -split [IO.Path]::PathSeparator | Where-Object { $_ -and $__povy_front -notcontains $_ })) -join [IO.Path]::PathSeparator')
    $lines.Add('Remove-Variable __povy_front')
    foreach ($path in $script:Prof.WindowsShell) {
        $literal = ConvertTo-PovyPsLiteral $path
        $lines.Add("if (Test-Path -LiteralPath $literal) { . $literal }")
    }
    $staged = New-PovyStagedFile (($lines -join "`n") + "`n")
    try {
        Install-PovyFile $staged $script:PovyInteractive
    } finally {
        Remove-Item -LiteralPath $staged -Force -ErrorAction Ignore
    }
}

function Get-PovyPsProfileBlock {
    $path = ConvertTo-PovyPsLiteral $script:PovyInteractive
    return @(
        (Get-PovyBlockMarker ''),
        '# Managed by povy. Edits inside this block are overwritten.',
        "if (Test-Path -LiteralPath $path) { . $path }",
        (Get-PovyBlockMarker '' -End)
    ) -join "`n"
}

# The block goes at the end, after anything else in the profile has set a prompt.
function Update-PovyPsProfile {
    Set-PovyBlock -File $script:PovyPsProfile -Block (Get-PovyPsProfileBlock) -Position bottom
}
