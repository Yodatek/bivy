# A profile is an external Git repository holding a profile.toml, read with the same
# rules as the bash engine. On Windows, povy sources the .ps1 files of its shell list
# and leaves the others to zsh and bash.

$script:PovySecretRe = '^[A-Za-z_][A-Za-z0-9_]*$'
$script:Prof = [ordered]@{
    Secrets = @(); Tools = [ordered]@{}; Prompt = ''; Packages = @(); Bin = ''; Shell = @(); Files = @()
}

# Arguments go in one array: a bare -- given to a PowerShell function never reaches it.
function Invoke-PovyGit([string[]]$Arguments) {
    $output = & git @Arguments 2>&1
    $code = $LASTEXITCODE
    return [pscustomobject]@{ Code = $code; Output = (@($output) -join "`n").Trim() }
}

# Clones the profile on its default branch, or on the branch given. The clone keeps
# the branch it was asked for, so that a new branch, or none, gives a new clone.
function Copy-PovyProfile([string]$Url, [string]$Branch) {
    $tmp = Join-Path $script:PovyStateDir ('profile-clone.' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    $cloneArgs = @('clone', '--quiet')
    if ($Branch) { $cloneArgs += @('--branch', $Branch) }
    $cloneArgs += @('--', $Url, (Join-Path $tmp 'profile'))
    $clone = Invoke-PovyGit $cloneArgs
    if ($clone.Code -eq 0) { $clone = Invoke-PovyGit @('-C', (Join-Path $tmp 'profile'), 'config', 'povy.branch', $Branch) }
    if ($clone.Code -ne 0) {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Ignore
        $suffix = if ($Branch) { ", branch $Branch" } else { '' }
        Stop-Povy "could not clone the profile: $Url$suffix"
    }
    if (Test-Path -LiteralPath $script:PovyProfileDir) { Remove-Item -LiteralPath $script:PovyProfileDir -Recurse -Force }
    Move-Item -LiteralPath (Join-Path $tmp 'profile') -Destination $script:PovyProfileDir
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction Ignore
    $suffix = if ($Branch) { ", branch $Branch" } else { '' }
    Write-PovyInfo "cloned profile $Url$suffix"
}

# An unreachable remote must not block a machine that already has its profile.
function Sync-PovyProfile([string]$Url, [string]$Branch) {
    if (-not $Url) { return }
    $current = Invoke-PovyGit @('-C', $script:PovyProfileDir, 'remote', 'get-url', 'origin')
    $currentBranch = Invoke-PovyGit @('-C', $script:PovyProfileDir, 'config', '--get', 'povy.branch')
    $currentUrl = if ($current.Code -eq 0) { $current.Output } else { '' }
    $branchNow = if ($currentBranch.Code -eq 0) { $currentBranch.Output } else { '' }
    if ($currentUrl -cne $Url -or $branchNow -cne $Branch) {
        Copy-PovyProfile $Url $Branch
    } elseif ((Invoke-PovyGit @('-C', $script:PovyProfileDir, 'pull', '--quiet', '--ff-only')).Code -ne 0) {
        Write-PovyWarning 'could not update the profile, using the local copy'
    }
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

# Rejects a template that is missing, is a link, or resolves outside the profile.
function Assert-PovyProfileFile([string]$Relative) {
    $path = Join-Path $script:PovyProfileRoot $Relative
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Ignore
    if (-not $item -or $item.LinkType -or $item -isnot [System.IO.FileInfo]) { Stop-Povy "profile template not found: $Relative" }
    if (-not (Test-PovyWithin $path $script:PovyProfileRoot)) { Stop-Povy "profile template is outside the profile: $Relative" }
}

function Assert-PovyProfileDir([string]$Relative) {
    $path = Join-Path $script:PovyProfileRoot $Relative
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { Stop-Povy "profile directory not found: $Relative" }
    if (-not (Test-PovyWithin $path $script:PovyProfileRoot)) { Stop-Povy "profile directory is outside the profile: $Relative" }
}

# Fills $script:Prof from the clone, or from its subdirectory given as the second
# argument. Stays empty when no profile is configured.
function Import-PovyProfile([string]$Url, [string]$Subdir) {
    $script:Prof = [ordered]@{
        Secrets = @(); Tools = [ordered]@{}; Prompt = ''; Packages = @(); Bin = ''; Shell = @(); Files = @()
    }
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
    $file = Join-Path $script:PovyProfileRoot 'profile.toml'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $suffix = if ($Subdir) { ", path $Subdir" } else { '' }
        Stop-Povy "the profile has no profile.toml: $Url$suffix"
    }
    $data = Read-PovyToml $file
    $prof = $script:Prof

    $secrets = Get-PovyTomlTable $data 'secrets' $file '[secrets]'
    if ($secrets.Contains('required')) {
        if (-not (Test-PovyStringList $secrets['required'])) { Stop-Povy "${file}: secrets.required must be a list of names" }
        foreach ($secret in $secrets['required']) {
            if ($secret -cnotmatch $script:PovySecretRe) { Stop-Povy "${file}: invalid secret name: $secret" }
        }
        $prof.Secrets = @($secrets['required'])
    }
    $prof.Tools = ConvertTo-PovyTool $data $file
    $prof.Prompt = Get-PovyTomlPrompt $data $file
    $prof.Packages = ConvertTo-PovyPackage $data $file

    # bin: a directory of commands put on PATH, read in place from the clone.
    $bin = (Get-PovyTomlString $data 'bin' $file).TrimEnd('/')
    if ($bin) {
        if (-not (Test-PovyRelativePath $bin)) { Stop-Povy "${file}: invalid bin: $bin" }
        Assert-PovyProfileDir $bin
        $prof.Bin = $bin
    }

    # shell: files sourced by interactive shells. PowerShell takes the .ps1 ones.
    if ($data.Contains('shell')) {
        if (-not (Test-PovyStringList $data['shell'])) { Stop-Povy "${file}: shell must be a list of files" }
        $shell = [System.Collections.Generic.List[string]]::new()
        foreach ($source in $data['shell']) {
            if (-not (Test-PovyRelativePath $source)) { Stop-Povy "${file}: invalid shell file: $source" }
            Assert-PovyProfileFile $source
            if ($source.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) { $shell.Add($source) }
        }
        $prof.Shell = $shell.ToArray()
    }

    if ($data.Contains('files')) {
        if ($data['files'] -isnot [System.Collections.IList] -or $data['files'] -is [string]) {
            Stop-Povy "${file}: files must be written as [[files]] tables"
        }
        $files = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $data['files']) {
            if ($entry -isnot [System.Collections.IDictionary]) { Stop-Povy "${file}: malformed [[files]] entry" }
            $source = Get-PovyTomlString $entry 'source' $file
            $target = Get-PovyTomlString $entry 'target' $file
            if (-not (Test-PovyRelativePath $source)) { Stop-Povy "${file}: invalid source: $source" }
            if (-not (Test-PovyRelativePath $target)) { Stop-Povy "${file}: target must stay in the home directory: $target" }
            Assert-PovyProfileFile $source
            $files.Add([pscustomobject]@{ Source = $source; Target = $target })
        }
        $prof.Files = $files.ToArray()
    }
}

# Replaces {{name}}, {{email}}, {{home}} and {{SECRET}}. Text that does not look like
# a placeholder is copied as is, so other template syntaxes pass through.
# Placeholders are case-sensitive, as in the bash engine.
function ConvertFrom-PovyTemplate([string]$Path) {
    $values = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $values['name'] = $script:Cfg.Name
    $values['email'] = $script:Cfg.Email
    $values['home'] = $script:PovyHome
    foreach ($secret in $script:Prof.Secrets) {
        $value = Get-PovyEnvValue $secret
        $values[$secret] = if ($null -eq $value) { '' } else { $value }
    }
    $pattern = '\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}'
    $text = [System.IO.File]::ReadAllText($Path)
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($text, $pattern)) {
        if (-not $values.ContainsKey($match.Groups[1].Value)) {
            Stop-Povy "unknown placeholder {{$($match.Groups[1].Value)}} in $Path"
        }
    }
    return $text -creplace $pattern, { $values[$_.Groups[1].Value] }
}
