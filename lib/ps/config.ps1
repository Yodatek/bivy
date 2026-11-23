# Machine configuration: config.toml and the .env secrets file, read with the same
# rules as the bash engine. Neither file is ever versioned, and .env is parsed, never
# run. Tools, packages and the prompt are mise configuration now, not povy's.

$script:PovyConfigHeader = '# Machine configuration for povy. Never versioned.'
$script:PovyRefRe = '^[A-Za-z0-9_][A-Za-z0-9._/-]*$'
$script:PovyContextIdRe = '^[a-z0-9][a-z0-9-]*$'
$script:PovyContextKeys = @('dir', 'name', 'email', 'profile', 'profile_ref', 'profile_path')
$script:Cfg = $null
# The shared .env, which a context reads after its own <id>.env.
$script:PovyEnvFallback = $null

function Test-PovyName([string]$Value) {
    return ($Value -and -not (Test-PovyControlChar $Value))
}

function Test-PovyEmail([string]$Value) {
    return ($Value -cmatch '^[^\s@]+@[^\s@]+$' -and -not (Test-PovyControlChar $Value))
}

# A path inside the profile or the home directory, written the same way on every
# system: forward slashes, no drive, no way up.
function Test-PovyRelativePath([string]$Path) {
    if (-not $Path -or $Path.StartsWith('/') -or $Path.StartsWith('~') -or $Path.EndsWith('/')) { return $false }
    if ($Path.Contains('\') -or $Path.Contains(':')) { return $false }
    if (('/' + $Path + '/') -match '/\.\.?/') { return $false }
    return -not (Test-PovyControlChar $Path)
}

# An empty URL means no profile. Credentials do not belong in config.toml.
function Get-PovyProfileUrlProblem([string]$Url) {
    if (-not $Url) { return '' }
    if ($Url.StartsWith('-') -or $Url.StartsWith('ext::') -or $Url.StartsWith('fd::')) {
        return "unsupported profile URL: $Url"
    }
    if ($Url -match '[\s\x00-\x1f\x7f]') { return 'profile URL contains whitespace or control characters' }
    if ($Url -match '://[^/@]+:[^/@]+@') {
        return 'profile URL must not embed a password; use a Git credential helper or SSH'
    }
    return ''
}

function Get-PovyTomlString($Data, [string]$Key, [string]$File) {
    if (-not $Data.Contains($Key) -or $null -eq $Data[$Key]) { return '' }
    $value = $Data[$Key]
    if ($value -isnot [string]) { Stop-Povy "${File}: $Key must be a string" }
    return $value
}

function Get-PovyTomlBool($Data, [string]$Key, [bool]$Default, [string]$File) {
    if (-not $Data.Contains($Key) -or $null -eq $Data[$Key]) { return $Default }
    if ($Data[$Key] -isnot [bool]) { Stop-Povy "${File}: $Key must be true or false" }
    return $Data[$Key]
}

function Get-PovyTomlTable($Data, [string]$Key, [string]$File, [string]$Hint) {
    if (-not $Data.Contains($Key) -or $null -eq $Data[$Key]) { return [ordered]@{} }
    $value = $Data[$Key]
    if ($value -isnot [System.Collections.IDictionary]) { Stop-Povy "${File}: $Key must be a table: $Hint" }
    return $value
}

function Test-PovyStringList($Value) {
    if ($Value -isnot [System.Collections.IList] -or $Value -is [string]) { return $false }
    foreach ($item in $Value) {
        if ($item -isnot [string]) { return $false }
    }
    return $true
}

# A directory for includeIf "gitdir/i:", under ~/, absolute, or on a drive, with
# forward slashes and a trailing one, so that it matches every repository below.
function ConvertTo-PovyIdentityDir([string]$Dir) {
    if (Test-PovyControlChar $Dir) { return $null }
    $dir = $Dir.Replace('\', '/')
    if ($dir -cnotmatch '^(~/|/|[A-Za-z]:/).') { return $null }
    if (-not $dir.EndsWith('/')) { $dir += '/' }
    return $dir
}

function ConvertTo-PovyIdentity($Data, [string]$File, [string]$DefaultName) {
    $identities = [System.Collections.Generic.List[object]]::new()
    if (-not $Data.Contains('identities') -or $null -eq $Data['identities']) { return , $identities.ToArray() }
    $list = $Data['identities']
    if ($list -isnot [System.Collections.IList] -or $list -is [string]) {
        Stop-Povy "${File}: identities must be written as [[identities]] tables"
    }
    $index = 0
    foreach ($entry in $list) {
        $index++
        $label = "identities entry $index"
        if ($entry -isnot [System.Collections.IDictionary]) { Stop-Povy "${File}: $label must be a table" }
        $dir = ConvertTo-PovyIdentityDir (Get-PovyTomlString $entry 'dir' $File)
        if (-not $dir) { Stop-Povy "${File}: ${label}: dir must start with ~/, / or a drive" }
        $name = Get-PovyTomlString $entry 'name' $File
        if (-not $name) { $name = $DefaultName }
        if (-not (Test-PovyName $name)) { Stop-Povy "${File}: ${label}: invalid name" }
        $email = Get-PovyTomlString $entry 'email' $File
        if (-not (Test-PovyEmail $email)) { Stop-Povy "${File}: ${label}: email is not a valid address" }
        $identities.Add([pscustomobject]@{ Dir = $dir; Name = $name; Email = $email })
    }
    return , $identities.ToArray()
}

# The [contexts.<id>] tables, in the order of the file, checked with the same rules
# as the bash engine: a Git identity, a profile, or both, below a directory.
function ConvertTo-PovyContext($Data, [string]$File, [string]$DefaultName) {
    $contexts = [System.Collections.Generic.List[object]]::new()
    $table = Get-PovyTomlTable $Data 'contexts' $File '[contexts.<id>]'
    $comparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $dirs = [System.Collections.Generic.HashSet[string]]::new($comparer)
    foreach ($id in @($table.Keys)) {
        if ($id -cnotmatch $script:PovyContextIdRe) {
            Stop-Povy "${File}: invalid context id: $id; use lowercase letters, digits and dashes"
        }
        $label = "contexts.$id"
        $entry = $table[$id]
        if ($entry -isnot [System.Collections.IDictionary]) { Stop-Povy "${File}: $label must be a table" }
        foreach ($key in @($entry.Keys)) {
            if ($key -cnotin $script:PovyContextKeys) { Stop-Povy "${File}: ${label}: unknown key: $key" }
        }
        $raw = Get-PovyTomlString $entry 'dir' $File
        if (-not $raw) { Stop-Povy "${File}: ${label}: dir is required" }
        $dir = ConvertTo-PovyIdentityDir $raw
        if (-not $dir) { Stop-Povy "${File}: ${label}: dir must start with ~/, / or a drive" }
        # Its conf.d file would be mise's global one.
        if ($comparer.Equals((Get-PovyContextPath $dir), $script:PovyHome)) {
            Stop-Povy "${File}: ${label}: dir must be below your home directory"
        }
        if (-not $dirs.Add($dir)) { Stop-Povy "${File}: ${label}: another context has the directory $dir" }
        $name = Get-PovyTomlString $entry 'name' $File
        $email = Get-PovyTomlString $entry 'email' $File
        $url = Get-PovyTomlString $entry 'profile' $File
        $ref = Get-PovyTomlString $entry 'profile_ref' $File
        $path = (Get-PovyTomlString $entry 'profile_path' $File).TrimEnd('/')
        if (-not $email -and -not $url) { Stop-Povy "${File}: ${label}: give it an email, a profile, or both" }
        if ($email) {
            if (-not $name) { $name = $DefaultName }
            if (-not (Test-PovyName $name)) { Stop-Povy "${File}: ${label}: invalid name" }
            if (-not (Test-PovyEmail $email)) { Stop-Povy "${File}: ${label}: email is not a valid address" }
        } elseif ($name) {
            Stop-Povy "${File}: ${label}: name needs an email"
        }
        $problem = Get-PovyProfileUrlProblem $url
        if ($problem) { Stop-Povy "${File}: ${label}: $problem" }
        if ($ref) {
            if (-not $url) { Stop-Povy "${File}: ${label}: profile_ref needs a profile" }
            if ($ref -cnotmatch $script:PovyRefRe -or $ref.Contains('..')) { Stop-Povy "${File}: ${label}: invalid profile_ref: $ref" }
        }
        if ($path) {
            if (-not $url) { Stop-Povy "${File}: ${label}: profile_path needs a profile" }
            if (-not (Test-PovyRelativePath $path)) { Stop-Povy "${File}: ${label}: invalid profile_path: $path" }
        }
        $contexts.Add([pscustomobject]@{
                Id = $id; Dir = $dir; Name = $name; Email = $email; Profile = $url; ProfileRef = $ref; ProfilePath = $path
            })
    }
    return , $contexts.ToArray()
}

# Settings that povy 0.1 read and that belong to mise now. A config that still has
# them stops with the way out, rather than having them ignored.
function Assert-PovyNoLegacyKey($Data, [string]$File) {
    $legacy = @('tools', 'packages', 'prompt' | Where-Object { $Data.Contains($_) })
    if ($legacy.Count -gt 0) {
        Stop-Povy "${File}: $($legacy -join ' '): since povy 0.2, tools, packages and the prompt are mise configuration; move them to ~/.config/mise/config.toml or to the profile's team.toml and mise.toml"
    }
}

function Read-PovyConfig([string]$File) {
    $data = Read-PovyToml $File
    Assert-PovyNoLegacyKey $data $File
    $cfg = [ordered]@{}
    $cfg.Name = Get-PovyTomlString $data 'name' $File
    $cfg.Email = Get-PovyTomlString $data 'email' $File
    $cfg.Profile = Get-PovyTomlString $data 'profile' $File
    $cfg.ProfileRef = Get-PovyTomlString $data 'profile_ref' $File
    $branch = Get-PovyTomlString $data 'profile_branch' $File
    $cfg.ProfilePath = (Get-PovyTomlString $data 'profile_path' $File).TrimEnd('/')
    if (-not (Test-PovyName $cfg.Name)) { Stop-Povy "${File}: name is required" }
    if (-not (Test-PovyEmail $cfg.Email)) { Stop-Povy "${File}: email is not a valid address" }
    # profile_branch is the name povy 0.1 used; profile_ref also takes a tag or a commit.
    $refKey = 'profile_ref'
    if ($branch) {
        if ($cfg.ProfileRef) { Stop-Povy "${File}: set profile_ref only, profile_branch is its old name" }
        $cfg.ProfileRef = $branch
        $refKey = 'profile_branch'
    }
    if ($cfg.ProfileRef) {
        if (-not $cfg.Profile) { Stop-Povy "${File}: $refKey needs a profile" }
        if ($cfg.ProfileRef -cnotmatch $script:PovyRefRe -or $cfg.ProfileRef.Contains('..')) {
            Stop-Povy "${File}: invalid ${refKey}: $($cfg.ProfileRef)"
        }
    }
    if ($cfg.ProfilePath) {
        if (-not $cfg.Profile) { Stop-Povy "${File}: profile_path needs a profile" }
        if (-not (Test-PovyRelativePath $cfg.ProfilePath)) { Stop-Povy "${File}: invalid profile_path: $($cfg.ProfilePath)" }
    }
    $problem = Get-PovyProfileUrlProblem $cfg.Profile
    if ($problem) { Stop-Povy "${File}: $problem" }
    $cfg.Identities = ConvertTo-PovyIdentity $data $File $cfg.Name
    $cfg.Contexts = ConvertTo-PovyContext $data $File $cfg.Name
    $cfg.Banner = Get-PovyTomlBool $data 'banner' $true $File
    $script:Cfg = $cfg
}

function Import-PovyConfig {
    if (-not (Test-Path -LiteralPath $script:PovyConfigFile -PathType Leaf)) {
        Stop-Povy "$script:PovyConfigFile not found; run: povy init"
    }
    Read-PovyConfig $script:PovyConfigFile
}

function ConvertTo-PovyTomlString([string]$Value) {
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

# Rewrites the three answers of povy init. The rest of an existing file, such as
# profile_ref or [[identities]], is kept as it is.
function Write-PovyConfig([string]$Name, [string]$Email, [string]$ProfileUrl) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($script:PovyConfigHeader)
    $lines.Add('name = ' + (ConvertTo-PovyTomlString $Name))
    $lines.Add('email = ' + (ConvertTo-PovyTomlString $Email))
    $lines.Add('profile = ' + (ConvertTo-PovyTomlString $ProfileUrl))
    if (Test-Path -LiteralPath $script:PovyConfigFile) {
        $tables = $false
        foreach ($line in [System.IO.File]::ReadAllLines($script:PovyConfigFile)) {
            if ($line -match '^\s*\[') { $tables = $true }
            if (-not $tables -and $line -match '^\s*(name|email|profile)\s*=') { continue }
            if (-not $tables -and $line -ceq $script:PovyConfigHeader) { continue }
            $lines.Add($line)
        }
    }
    $staged = New-PovyStagedFile (($lines -join "`n") + "`n")
    try {
        try {
            Read-PovyConfig $staged
        } catch {
            Stop-Povy "could not update $script:PovyConfigFile; fix it by hand or remove it"
        }
        Install-PovyFile $staged $script:PovyConfigFile -Private
    } finally {
        Remove-Item -LiteralPath $staged -Force -ErrorAction Ignore
    }
}

function Initialize-PovyEnvFile {
    if (-not (Test-Path -LiteralPath $script:PovyEnvFile)) {
        [System.IO.File]::WriteAllText($script:PovyEnvFile, "# Secrets for povy. Never versioned.`n", $script:PovyUtf8)
        Write-PovyInfo "wrote $script:PovyEnvFile"
    }
    Set-PovyPrivate $script:PovyEnvFile
}

# The value of a key in one file, or $null when the key has no line. The last line
# wins, as it would in a shell. Surrounding quotes are removed, CRLF is tolerated.
function Get-PovyEnvFileValue([string]$File, [string]$Key) {
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $value = $null
    foreach ($line in [System.IO.File]::ReadAllLines($File)) {
        $line = $line.TrimEnd("`r").TrimStart()
        if ($line.StartsWith('export ')) { $line = $line.Substring(7) }
        if ($line.StartsWith("$Key=", [StringComparison]::Ordinal)) { $value = $line.Substring($Key.Length + 1) }
    }
    if ($null -eq $value) { return $null }
    if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    return $value
}

# The value of a secret of the current context: the first value that is not empty,
# in its .env, then in the shared one. '' when a file has the key with no value,
# $null when no file has it.
function Get-PovyEnvValue([string]$Key) {
    $found = $null
    foreach ($file in @($script:PovyEnvFile, $script:PovyEnvFallback) | Where-Object { $_ }) {
        $value = Get-PovyEnvFileValue $file $Key
        if ($null -eq $value) { continue }
        if ($value) { return $value }
        $found = ''
    }
    return $found
}

# Adds an empty line to the current .env for each listed key that no file has, and
# creates that file, private, when it needs one. Existing lines stay.
function Add-PovyEnvSeed([string[]]$Keys) {
    foreach ($key in $Keys) {
        if ($null -ne (Get-PovyEnvValue $key)) { continue }
        if (-not (Test-Path -LiteralPath $script:PovyEnvFile)) {
            [System.IO.File]::WriteAllText($script:PovyEnvFile, "# Secrets for povy. Never versioned.`n", $script:PovyUtf8)
            Set-PovyPrivate $script:PovyEnvFile
            Write-PovyInfo "wrote $script:PovyEnvFile"
        }
        $text = [System.IO.File]::ReadAllText($script:PovyEnvFile)
        $prefix = if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { "`n" } else { '' }
        [System.IO.File]::AppendAllText($script:PovyEnvFile, "$prefix$key=`n", $script:PovyUtf8)
    }
}

function Get-PovyEnvMissing([string[]]$Keys) {
    return @($Keys | Where-Object { -not (Get-PovyEnvValue $_) })
}
