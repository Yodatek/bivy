# A profile is a team's Git repository in mise's own format, read as the bash engine
# reads it: team.toml, which mise includes in every directory; mise.toml, the
# project that mise bootstrap applies; and its [_.povy] table, which mise ignores:
#   bin               a directory of commands that povy puts on every PATH
#   [_.povy.windows]  files: [bootstrap.files] targets that povy writes on Windows,
#                     where mise writes none; shell: .ps1 files that interactive
#                     PowerShell sources

# An expression may span lines, as in Tera.
$script:PovyTemplatePattern = '(?s)\{\{(.*?)\}\}'

# Names of secrets and vars match exactly, as in mise.
function New-PovyNameTable {
    return [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
}

function New-PovyProfileState {
    return [ordered]@{
        Team = ''; Project = ''; Bin = ''; Secrets = (New-PovyNameTable); Vars = (New-PovyNameTable)
        WindowsFiles = @(); WindowsShell = @()
    }
}
$script:Prof = New-PovyProfileState

# Arguments go in one array: a bare -- given to a PowerShell function never reaches it.
function Invoke-PovyGit([string[]]$Arguments) {
    $output = & git @Arguments 2>&1
    $code = $LASTEXITCODE
    return [pscustomobject]@{ Code = $code; Output = (@($output) -join "`n").Trim() }
}

# Clones the profile, then checks out the ref given: a branch, a tag or a commit.
# The clone keeps the ref it was asked for, so that another ref, or none, gives a
# new clone.
function Copy-PovyProfile([string]$Url, [string]$Ref) {
    $tmp = Join-Path $script:PovyStateDir ('profile-clone.' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    $clone = Join-Path $tmp 'profile'
    $result = Invoke-PovyGit @('clone', '--quiet', '--', $Url, $clone)
    if ($result.Code -eq 0 -and $Ref) { $result = Invoke-PovyGit @('-C', $clone, 'checkout', '--quiet', $Ref, '--') }
    if ($result.Code -eq 0) { $result = Invoke-PovyGit @('-C', $clone, 'config', 'povy.ref', $Ref) }
    $suffix = if ($Ref) { ", ref $Ref" } else { '' }
    if ($result.Code -ne 0) {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Ignore
        Stop-Povy "could not clone the profile: $Url$suffix"
    }
    if (Test-Path -LiteralPath $script:PovyProfileDir) { Remove-Item -LiteralPath $script:PovyProfileDir -Recurse -Force }
    Move-Item -LiteralPath $clone -Destination $script:PovyProfileDir
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Ignore
    Write-PovyInfo "cloned profile $Url$suffix"
}

# A branch follows its remote; a tag is looked up again, as it may have moved; a
# commit stays. An unreachable remote must not block a machine that already has
# its profile.
function Sync-PovyProfile([string]$Url, [string]$Ref) {
    if (-not $Url) { return }
    $dir = $script:PovyProfileDir
    $current = Invoke-PovyGit @('-C', $dir, 'remote', 'get-url', 'origin')
    $currentRef = Invoke-PovyGit @('-C', $dir, 'config', '--get', 'povy.ref')
    $currentUrl = if ($current.Code -eq 0) { $current.Output } else { '' }
    if ($currentUrl -cne $Url -or $currentRef.Code -ne 0 -or $currentRef.Output -cne $Ref) {
        Copy-PovyProfile $Url $Ref
        return
    }
    if ((Invoke-PovyGit @('-C', $dir, 'symbolic-ref', '--quiet', 'HEAD')).Code -eq 0) {
        $ok = (Invoke-PovyGit @('-C', $dir, 'pull', '--quiet', '--ff-only')).Code -eq 0
    } else {
        $ok = (Invoke-PovyGit @('-C', $dir, 'fetch', '--quiet', '--tags', '--force', 'origin')).Code -eq 0 -and
            (Invoke-PovyGit @('-C', $dir, 'checkout', '--quiet', $Ref, '--')).Code -eq 0
    }
    if (-not $ok) { Write-PovyWarning 'could not update the profile, using the local copy' }
}

# The real path of a file or directory, with links followed.
function Resolve-PovyRealPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Ignore
    if (-not $item) { return $null }
    $parts = [System.Collections.Generic.List[string]]::new()
    while ($item) {
        if ($item.LinkType) {
            $target = $item.ResolveLinkTarget($true)
            if (-not $target) { return $null }
            $resolved = $target.FullName
            for ($i = $parts.Count - 1; $i -ge 0; $i--) { $resolved = Join-Path $resolved $parts[$i] }
            return Resolve-PovyRealPath $resolved
        }
        $parent = if ($item -is [System.IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
        if (-not $parent) { break }
        $parts.Add($item.Name)
        $item = $parent
    }
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-PovyWithin([string]$Path, [string]$Base) {
    $real = Resolve-PovyRealPath $Path
    $root = Resolve-PovyRealPath $Base
    if (-not $real -or -not $root) { return $false }
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $root = $root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return ($real + [System.IO.Path]::DirectorySeparatorChar).StartsWith($root, $comparison)
}

# The path of a file of the profile, when it is a regular file inside it.
function Get-PovyProfileFile([string]$Relative) {
    $path = Join-Path $script:PovyProfileRoot $Relative
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Ignore
    if (-not $item) { return '' }
    if ($item.LinkType -or $item -isnot [System.IO.FileInfo] -or -not (Test-PovyWithin $path $script:PovyProfileRoot)) {
        Stop-Povy "the profile's $Relative must be a regular file inside the profile"
    }
    return $item.FullName
}

# Sets $script:PovyProfileRoot and $script:Prof from the clone, or from its
# subdirectory given as the second argument. Both stay empty without a profile.
function Import-PovyProfile([string]$Url, [string]$Subdir) {
    $script:Prof = New-PovyProfileState
    $script:PovyProfileRoot = $script:PovyProfileDir
    if (-not $Url) { return }
    if ($Subdir) {
        $script:PovyProfileRoot = Join-Path $script:PovyProfileDir $Subdir
        if (-not (Test-Path -LiteralPath $script:PovyProfileRoot -PathType Container)) {
            Stop-Povy "the profile repository has no directory ${Subdir}: $Url"
        }
        if (-not (Test-PovyWithin $script:PovyProfileRoot $script:PovyProfileDir)) {
            Stop-Povy "profile_path is outside the profile: $Subdir"
        }
    }
    $prof = $script:Prof
    $prof.Team = Get-PovyProfileFile 'team.toml'
    $prof.Project = Get-PovyProfileFile 'mise.toml'
    if (-not $prof.Team -and -not $prof.Project) {
        if (Test-Path -LiteralPath (Join-Path $script:PovyProfileRoot 'profile.toml')) {
            Stop-Povy "the profile is in the povy 0.1 format, profile.toml; convert it to team.toml and mise.toml, as _samples/profile shows: $Url"
        }
        $suffix = if ($Subdir) { ", path $Subdir" } else { '' }
        Stop-Povy "the profile has neither team.toml nor mise.toml: $Url$suffix"
    }
    foreach ($file in @($prof.Team, $prof.Project) | Where-Object { $_ }) {
        $data = Read-PovyToml $file
        $vars = Get-PovyTomlTable $data 'vars' $file '[vars]'
        foreach ($name in $vars.Keys) {
            $text = ConvertTo-PovyVarText $vars[$name]
            if ($null -ne $text) { $prof.Vars[$name] = $text }
        }
    }
    if ($prof.Project) { Import-PovyProject $prof.Project }
}

# A [vars] value as a template writes it: strings, numbers and booleans, as Tera
# prints them. Tables and lists are left out.
function ConvertTo-PovyVarText($Value) {
    if ($Value -is [string]) { return $Value }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return $null
}

# Reads the parts of mise.toml that povy acts on: [_.povy], the secrets that
# templates read, and the [bootstrap.files] entries it writes on Windows.
function Import-PovyProject([string]$File) {
    $prof = $script:Prof
    $data = Read-PovyToml $File
    $free = Get-PovyTomlTable $data '_' $File '[_]'
    $povy = Get-PovyTomlTable $free 'povy' $File '[_.povy]'

    $bin = (Get-PovyTomlString $povy 'bin' $File).TrimEnd('/')
    if ($bin) {
        if (-not (Test-PovyRelativePath $bin)) { Stop-Povy "${File}: invalid _.povy.bin: $bin" }
        $path = Join-Path $script:PovyProfileRoot $bin
        if (-not (Test-Path -LiteralPath $path -PathType Container) -or -not (Test-PovyWithin $path $script:PovyProfileRoot)) {
            Stop-Povy "${File}: _.povy.bin is not a directory of the profile: $bin"
        }
        $prof.Bin = [System.IO.Path]::GetFullPath($path)
    }

    $bootstrap = Get-PovyTomlTable $data 'bootstrap' $File '[bootstrap]'
    $secrets = Get-PovyTomlTable $bootstrap 'secrets' $File '[bootstrap.secrets]'
    foreach ($name in $secrets.Keys) {
        $value = $secrets[$name]
        $envName = if ($value -is [string]) { $value } elseif ($value -is [System.Collections.IDictionary]) { [string]$value['env'] } else { '' }
        if ($envName -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') { Stop-Povy "${File}: bootstrap.secrets.$name needs an environment variable" }
        $prof.Secrets[$name] = $envName
    }

    $windows = Get-PovyTomlTable $povy 'windows' $File '[_.povy.windows]'
    $files = Get-PovyTomlTable $bootstrap 'files' $File '[bootstrap.files]'
    if ($windows.Contains('files')) {
        if (-not (Test-PovyStringList $windows['files'])) { Stop-Povy "${File}: _.povy.windows.files must be a list of targets" }
        $prof.WindowsFiles = @(foreach ($target in $windows['files']) { ConvertTo-PovyWindowsFile $files $target $File })
    }
    if ($windows.Contains('shell')) {
        if (-not (Test-PovyStringList $windows['shell'])) { Stop-Povy "${File}: _.povy.windows.shell must be a list of files" }
        $prof.WindowsShell = @(foreach ($source in $windows['shell']) {
                if (-not (Test-PovyRelativePath $source) -or -not $source.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
                    Stop-Povy "${File}: _.povy.windows.shell takes .ps1 files of the profile: $source"
                }
                $path = Get-PovyProfileFile $source
                if (-not $path) { Stop-Povy "${File}: profile file not found: $source" }
                $path
            })
    }
}

# A [bootstrap.files] entry as povy writes it on Windows: a whole file in the home
# directory, from content or from a source of the profile, a template or not.
function ConvertTo-PovyWindowsFile($Files, [string]$Target, [string]$File) {
    if (-not $Files.Contains($Target) -or $Files[$Target] -isnot [System.Collections.IDictionary]) {
        Stop-Povy "${File}: _.povy.windows.files names $Target, which [bootstrap.files] does not declare"
    }
    $entry = $Files[$Target]
    $relative = if ($Target.StartsWith('~/')) { $Target.Substring(2) } else { '' }
    if (-not (Test-PovyRelativePath $relative)) { Stop-Povy "${File}: povy writes Windows files under ~/ only: $Target" }
    foreach ($key in $entry.Keys) {
        if ($key -notin @('content', 'source', 'template', 'mode', 'os')) {
            Stop-Povy "${File}: povy writes whole files on Windows, without $key`: $Target"
        }
    }
    $content = Get-PovyTomlString $entry 'content' $File
    $source = Get-PovyTomlString $entry 'source' $File
    if ([bool]$content -eq [bool]$source) { Stop-Povy "${File}: $Target needs either content or source" }
    if ($source) {
        $relativeSource = $source -replace '^\./', ''
        if (-not (Test-PovyRelativePath $relativeSource)) { Stop-Povy "${File}: invalid source for ${Target}: $source" }
        $path = Get-PovyProfileFile $relativeSource
        if (-not $path) { Stop-Povy "${File}: source not found for ${Target}: $source" }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $content = [System.Text.UTF8Encoding]::new($false).GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    } else {
        $bom = $false
    }
    $mode = Get-PovyTomlString $entry 'mode' $File
    return [pscustomobject]@{
        Target = $Target
        Path = Join-Path $script:PovyHome $relative
        Content = $content
        Template = (Get-PovyTomlBool $entry 'template' $false $File)
        # A source keeps its byte order mark, as mise copies it.
        Bom = $bom
        # Group and others get nothing: the file is for its owner alone.
        Private = [bool]($mode -match '^0?[0-7]00$')
    }
}

# Renders the templates that mise would render elsewhere, with only what they need
# here: {{ secret(name="...") }} and {{ vars.name }}. Anything else that Tera would
# read stops, rather than being written as it is.
function ConvertFrom-PovyTemplate([string]$Text, [string]$Label) {
    if ($Text -match '\{%|\{#') { Stop-Povy "${Label}: povy on Windows renders only secret() and vars in templates" }
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Text, $script:PovyTemplatePattern)) {
        $null = Get-PovyTemplateValue $match.Groups[1].Value $Label
    }
    if (($Text -creplace $script:PovyTemplatePattern, '').Contains('{{')) {
        Stop-Povy "${Label}: a {{ has no closing }}"
    }
    return $Text -creplace $script:PovyTemplatePattern, { Get-PovyTemplateValue $_.Groups[1].Value $Label }
}

function Get-PovyTemplateValue([string]$Expression, [string]$Label) {
    $expression = $Expression.Trim()
    if ($expression -cmatch '^secret\(\s*name\s*=\s*(["''])([A-Za-z0-9._-]+)\1\s*\)$') {
        $name = $Matches[2]
        if (-not $script:Prof.Secrets.ContainsKey($name)) { Stop-Povy "${Label}: the secret $name is not declared in [bootstrap.secrets]" }
        $envName = $script:Prof.Secrets[$name]
        $value = Get-PovyEnvValue $envName
        if (-not $value) { $value = [Environment]::GetEnvironmentVariable($envName) }
        if (-not $value) { Stop-Povy "${Label}: the secret $name is empty; fill $envName in $script:PovyEnvFile" }
        return $value
    }
    if ($expression -cmatch '^vars\.([A-Za-z_][A-Za-z0-9_]*)$') {
        $name = $Matches[1]
        if (-not $script:Prof.Vars.ContainsKey($name)) { Stop-Povy "${Label}: vars.$name is not declared in [vars]" }
        return $script:Prof.Vars[$name]
    }
    Stop-Povy "${Label}: povy on Windows renders only secret() and vars in templates, not {{ $expression }}"
}
