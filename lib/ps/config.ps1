# Machine configuration: config.toml and the .env secrets file, read with the same
# rules as the bash engine. Neither file is ever versioned, and .env is parsed, never
# run.

$script:PovyStarshipTool = 'starship@1.27.0'
$script:PovyConfigHeader = '# Machine configuration for povy. Never versioned.'
$script:PovyPackageManagers = @('brew', 'cask', 'apt', 'dnf', 'winget')
$script:PovyToolNameRe = '^[A-Za-z0-9@][A-Za-z0-9@._:/+-]*$'
$script:PovyToolVersionRe = '^[A-Za-z0-9][A-Za-z0-9._:+-]*$'
$script:PovyPackageRe = '^[A-Za-z0-9][A-Za-z0-9._+@/-]*$'
$script:PovyBranchRe = '^[A-Za-z0-9_][A-Za-z0-9._/-]*$'
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

function Get-PovyTomlPrompt($Data, [string]$File) {
    $value = Get-PovyTomlString $Data 'prompt' $File
    if ($value -notin @('', 'starship', 'none')) { Stop-Povy "${File}: prompt must be starship or none" }
    return $value
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

# Tools as an ordered table of name to versions. A tool takes one version or a list,
# all installed, the first one the default.
function ConvertTo-PovyTool($Data, [string]$File) {
    $tools = [ordered]@{}
    $table = Get-PovyTomlTable $Data 'tools' $File '[tools]'
    foreach ($name in $table.Keys) {
        if ($name -cnotmatch $script:PovyToolNameRe) { Stop-Povy "${File}: invalid tool name: $name" }
        $value = $table[$name]
        if ($value -is [int] -or $value -is [long]) { $value = [string]$value }
        if ($value -is [string]) {
            $versions = @($value)
        } elseif ((Test-PovyStringList $value) -and $value.Count -gt 0) {
            $versions = @($value)
        } else {
            Stop-Povy "${File}: invalid version list for $name"
        }
        foreach ($version in $versions) {
            if ($version -cnotmatch $script:PovyToolVersionRe) { Stop-Povy "${File}: invalid version for $name" }
        }
        $tools[$name] = [string[]]$versions
    }
    return $tools
}

# Packages as a list of @{ Manager; Name }.
function ConvertTo-PovyPackage($Data, [string]$File) {
    $packages = [System.Collections.Generic.List[object]]::new()
    $table = Get-PovyTomlTable $Data 'packages' $File '[packages]'
    foreach ($manager in $table.Keys) {
        if ($manager -notin $script:PovyPackageManagers) {
            Stop-Povy "${File}: unknown package manager: $manager (use $($script:PovyPackageManagers -join ' '))"
        }
        $names = $table[$manager]
        if ($names -isnot [System.Collections.IList] -or $names -is [string]) { Stop-Povy "${File}: packages.$manager must be a list" }
        if (-not (Test-PovyStringList $names)) { Stop-Povy "${File}: packages.$manager must be a list of names" }
        foreach ($name in $names) {
            if ($name -cnotmatch $script:PovyPackageRe) { Stop-Povy "${File}: invalid package name for ${manager}: $name" }
            $packages.Add([pscustomobject]@{ Manager = $manager; Name = $name })
        }
    }
    return , $packages.ToArray()
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

function Read-PovyConfig([string]$File) {
    $data = Read-PovyToml $File
    $cfg = [ordered]@{}
    $cfg.Name = Get-PovyTomlString $data 'name' $File
    $cfg.Email = Get-PovyTomlString $data 'email' $File
    $cfg.Profile = Get-PovyTomlString $data 'profile' $File
    $cfg.ProfileBranch = Get-PovyTomlString $data 'profile_branch' $File
    $cfg.ProfilePath = (Get-PovyTomlString $data 'profile_path' $File).TrimEnd('/')
    if (-not (Test-PovyName $cfg.Name)) { Stop-Povy "${File}: name is required" }
    if (-not (Test-PovyEmail $cfg.Email)) { Stop-Povy "${File}: email is not a valid address" }
    if ($cfg.ProfileBranch) {
        if (-not $cfg.Profile) { Stop-Povy "${File}: profile_branch needs a profile" }
        if ($cfg.ProfileBranch -cnotmatch $script:PovyBranchRe -or $cfg.ProfileBranch.Contains('..')) {
            Stop-Povy "${File}: invalid profile_branch: $($cfg.ProfileBranch)"
        }
    }
    if ($cfg.ProfilePath) {
        if (-not $cfg.Profile) { Stop-Povy "${File}: profile_path needs a profile" }
        if (-not (Test-PovyRelativePath $cfg.ProfilePath)) { Stop-Povy "${File}: invalid profile_path: $($cfg.ProfilePath)" }
    }
    $problem = Get-PovyProfileUrlProblem $cfg.Profile
    if ($problem) { Stop-Povy "${File}: $problem" }
    $cfg.Tools = ConvertTo-PovyTool $data $File
    $cfg.Identities = ConvertTo-PovyIdentity $data $File $cfg.Name
    $cfg.Banner = Get-PovyTomlBool $data 'banner' $true $File
    $cfg.Prompt = Get-PovyTomlPrompt $data $File
    $cfg.Packages = ConvertTo-PovyPackage $data $File
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
# [tools] or [[identities]], is kept as it is.
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

# The prompt to set: the machine's choice, else the profile's, else none.
function Get-PovyPromptChoice {
    $choice = if ($script:Cfg.Prompt) { $script:Cfg.Prompt } else { $script:Prof.Prompt }
    if (-not $choice) { return 'none' }
    return $choice
}

# Every tool with its versions and the level that declares it, the last declaration
# of a name winning: povy itself, then the profile, then the machine. yq is declared
# because mise makes a shim for every installed tool, and a shim with no configured
# version fails when called.
function Get-PovyMergedTool {
    $merged = [ordered]@{}
    $add = {
        param($Name, $Versions, $Level)
        $merged[$Name] = [pscustomobject]@{ Name = $Name; Versions = [string[]]$Versions; Level = $Level }
    }
    $yq = $script:PovyYqTool.Split('@')
    & $add $yq[0] @($yq[1]) 'povy'
    if ((Get-PovyPromptChoice) -eq 'starship') {
        $starship = $script:PovyStarshipTool.Split('@')
        & $add $starship[0] @($starship[1]) 'povy'
    }
    foreach ($name in $script:Prof.Tools.Keys) { & $add $name $script:Prof.Tools[$name] 'profile' }
    foreach ($name in $script:Cfg.Tools.Keys) { & $add $name $script:Cfg.Tools[$name] 'machine' }
    return @($merged.Values)
}
