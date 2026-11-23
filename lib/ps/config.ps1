# Machine configuration: config.toml and the .env secrets file, read with the same
# rules as the bash engine. Neither file is ever versioned, and .env is parsed, never
# run. Tools, packages and the prompt are mise configuration now, not povy's.

$script:PovyConfigHeader = '# Machine configuration for povy. Never versioned.'
$script:PovyRefRe = '^[A-Za-z0-9_][A-Za-z0-9._/-]*$'
$script:Cfg = $null

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

# The value of a key in .env, or $null when the key has no line. The last line wins,
# as it would in a shell. Surrounding quotes are removed, CRLF is tolerated.
function Get-PovyEnvValue([string]$Key) {
    if (-not (Test-Path -LiteralPath $script:PovyEnvFile)) { return $null }
    $value = $null
    foreach ($line in [System.IO.File]::ReadAllLines($script:PovyEnvFile)) {
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

# Adds an empty line for each listed key that has none; existing lines stay.
function Add-PovyEnvSeed([string[]]$Keys) {
    foreach ($key in $Keys) {
        if ($null -ne (Get-PovyEnvValue $key)) { continue }
        $text = [System.IO.File]::ReadAllText($script:PovyEnvFile)
        $prefix = if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { "`n" } else { '' }
        [System.IO.File]::AppendAllText($script:PovyEnvFile, "$prefix$key=`n", $script:PovyUtf8)
    }
}

function Get-PovyEnvMissing([string[]]$Keys) {
    return @($Keys | Where-Object { -not (Get-PovyEnvValue $_) })
}
