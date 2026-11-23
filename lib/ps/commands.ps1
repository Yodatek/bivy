# The commands of povy on Windows. Each one starts from the same steps as in the bash
# engine, and apply writes nothing until the configuration, the secrets and every
# template have been checked.

function Show-PovyUsage {
    @'
Usage: povy <command>

Commands:
  init [--config <file>]   Write ~/.config/povy/config.toml and .env
  apply                    Apply the profile with mise bootstrap, put the tools on
                           the PATH of every shell and app, set the Git identity
  doctor                   Check the real state; exits 1 if something is wrong
  version                  Show the version of povy
  help                     Show this message
'@
}

# The release the engine is on, read from its Git clone, as in the bash engine.
function Get-PovyVersion {
    $result = Invoke-PovyGit @('-C', $script:PovyRoot, 'describe', '--match', 'v[0-9]*', '--always', '--dirty')
    if ($result.Code -ne 0 -or -not $result.Output) { return 'unknown' }
    return $result.Output -replace '^v', ''
}

function Initialize-PovyCommand {
    Initialize-PovyPath
    Initialize-PovyDirectory
    Assert-PovyMiseRecent
    Install-PovyYq
    Import-PovyConfig
    Initialize-PovyEnvFile
}

function Read-PovyAnswer([string]$Label, [string]$Default) {
    $prompt = if ($Default) { "$Label [$Default]" } else { $Label }
    $answer = Read-Host -Prompt $prompt
    if (-not $answer) { return $Default }
    return $answer.Trim()
}

function Invoke-PovyInitPrompt {
    $name = ''; $email = ''; $profileUrl = ''
    if (Test-Path -LiteralPath $script:PovyConfigFile) {
        Read-PovyConfig $script:PovyConfigFile
        $name = $script:Cfg.Name; $email = $script:Cfg.Email; $profileUrl = $script:Cfg.Profile
    } elseif (Get-Command git -CommandType Application -ErrorAction Ignore) {
        $name = (Invoke-PovyGit @('config', '--global', 'user.name')).Output
        $email = (Invoke-PovyGit @('config', '--global', 'user.email')).Output
    }
    while ($true) {
        $answer = Read-PovyAnswer 'Name' $name
        if (Test-PovyName $answer) { $name = $answer; break }
        Write-PovyInfo 'A name is required.'
    }
    while ($true) {
        $answer = Read-PovyAnswer 'E-mail' $email
        if (Test-PovyEmail $answer) { $email = $answer; break }
        Write-PovyInfo 'That does not look like an e-mail address.'
    }
    while ($true) {
        $answer = Read-PovyAnswer "Profile Git URL (optional, 'none' for no profile)" $profileUrl
        if ($answer -eq 'none') { $answer = '' }
        $problem = Get-PovyProfileUrlProblem $answer
        if (-not $problem) { $profileUrl = $answer; break }
        Write-PovyInfo $problem
    }
    Write-PovyConfig $name $email $profileUrl
}

function Invoke-PovyInit([string[]]$Arguments) {
    $configFile = ''
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -eq '--config') {
            if ($i + 1 -ge $Arguments.Count) { Stop-Povy '--config needs a file' }
            $configFile = $Arguments[++$i]
        } else {
            Stop-Povy "unknown option for init: $($Arguments[$i])"
        }
    }
    Initialize-PovyPath
    Initialize-PovyDirectory
    Assert-PovyMiseRecent
    Install-PovyYq
    $interactive = -not $configFile
    if ($interactive) {
        if ([Console]::IsInputRedirected) { Stop-Povy 'no terminal available; use: povy init --config <file>' }
        Invoke-PovyInitPrompt
    } else {
        if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) { Stop-Povy "cannot read $configFile" }
        $configFile = [System.IO.Path]::GetFullPath($configFile)
        Read-PovyConfig $configFile
        if ($configFile -ne $script:PovyConfigFile) { Install-PovyFile $configFile $script:PovyConfigFile -Private }
        Set-PovyPrivate $script:PovyConfigFile
    }
    Initialize-PovyEnvFile
    Import-PovyConfig
    Sync-PovyProfile $script:Cfg.Profile $script:Cfg.ProfileRef
    Import-PovyProfile $script:Cfg.Profile $script:Cfg.ProfilePath
    Set-PovyMiseTrust
    $names = @(Get-PovySecretName)
    Add-PovyEnvSeed $names
    $missing = @(Get-PovySecretMissing $names)
    if ($missing.Count -gt 0) {
        if ($interactive) {
            Write-PovyInfo "The profile needs secrets; opening $script:PovyEnvFile"
            $editor = if ($env:EDITOR) { $env:EDITOR } elseif ($IsWindows) { 'notepad.exe' } else { 'vi' }
            Start-Process -FilePath $editor -ArgumentList ('"{0}"' -f $script:PovyEnvFile) -Wait -NoNewWindow
            Set-PovyPrivate $script:PovyEnvFile
            $missing = @(Get-PovySecretMissing $names)
        }
        if ($missing.Count -gt 0) {
            Write-PovyWarning "fill these secrets in $script:PovyEnvFile before povy apply:"
            Write-PovyInfo ($missing -join "`n")
        }
    }
    Write-PovyInfo 'Next: povy apply'
}

# Nothing in the home directory changes until the secrets are filled in and the
# Windows files are rendered. mise bootstrap then applies the profile, and povy does
# what mise does not do on Windows.
function Invoke-PovyApply {
    Initialize-PovyCommand
    Sync-PovyProfile $script:Cfg.Profile $script:Cfg.ProfileRef
    Import-PovyProfile $script:Cfg.Profile $script:Cfg.ProfilePath
    Set-PovyMiseTrust
    $names = @(Get-PovySecretName)
    Add-PovyEnvSeed $names
    $missing = @(Get-PovySecretMissing $names)
    if ($missing.Count -gt 0) {
        Write-PovyInfo ($missing -join "`n")
        Stop-Povy "the secrets above are empty; fill them in $script:PovyEnvFile"
    }
    # Elsewhere, mise bootstrap writes these files itself.
    $rendered = if ($IsWindows) { @(Get-PovyWindowsFileContent) } else { @() }

    Write-PovyMiseConf
    Invoke-PovyBootstrap $names
    Invoke-PovyMise reshim | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Povy 'mise could not refresh its shims' }
    Update-PovyUserPath
    Write-PovyInteractive
    Update-PovyPsProfile
    Update-PovyGit
    Install-PovyWindowsFile $rendered

    Write-PovyInfo "Applied: $script:PovyWritten written, $script:PovyUnchanged unchanged, $script:PovyBackedUp backed up."
    if ($script:PovyBackedUp -gt 0) { Write-PovyInfo "Backups are in $script:PovyBackupDir" }
    Write-PovyInfo 'Open a new terminal, or restart an app, for it to see the new PATH.'
}

$script:DoctorFailed = $false

function Write-PovyDoctorOk([string]$Message) { Write-Output "[ok]   $Message" }
function Write-PovyDoctorWarning([string]$Message) { Write-Output "[warn] $Message" }
function Write-PovyDoctorFailure([string]$Message) {
    Write-Output "[FAIL] $Message"
    $script:DoctorFailed = $true
}

# The commands of the active mise tools, which the shims must provide.
function Get-PovyMiseCommand {
    $dirs = @(Invoke-PovyMise bin-paths 2>$null)
    if ($LASTEXITCODE -ne 0) { return @() }
    $extensions = if ($IsWindows) { @('.exe', '.cmd', '.bat', '.ps1') } else { @('') }
    $names = foreach ($dir in $dirs) {
        foreach ($file in @(Get-ChildItem -LiteralPath ([string]$dir).Trim() -File -ErrorAction Ignore)) {
            if ($IsWindows -and $file.Extension -notin $extensions) { continue }
            [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        }
    }
    return @($names | Sort-Object -Unique)
}

# Windows gives new processes the system PATH before the user PATH, so a tool that
# is also installed for the whole machine wins over the mise shim.
function Test-PovyShadowedShim {
    if (-not $IsWindows) { return }
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $shims = ConvertTo-PovyComparablePath $script:PovyShimsDir
    $dirs = @(($machine + ';' + (Get-PovyUserPathValue)) -split ';' | Where-Object { $_ })
    $shadowed = foreach ($name in Get-PovyMiseCommand) {
        foreach ($dir in $dirs) {
            $expanded = [Environment]::ExpandEnvironmentVariables($dir)
            if ((ConvertTo-PovyComparablePath $dir) -eq $shims) { break }
            $hit = @('.exe', '.cmd', '.bat') | Where-Object { Test-Path -LiteralPath (Join-Path $expanded "$name$_") } | Select-Object -First 1
            if ($hit) { "$name ($expanded)"; break }
        }
    }
    if (@($shadowed).Count -gt 0) {
        Write-PovyDoctorWarning "the system PATH comes first in new processes, so these hide the mise shims outside PowerShell: $($shadowed -join ', ')"
    }
}

function Test-PovyDoctorProfile {
    try {
        Import-PovyProfile $script:Cfg.Profile $script:Cfg.ProfilePath
    } catch {
        Write-PovyDoctorFailure "the profile is missing or invalid; run: povy apply ($($_.Exception.Message))"
        return
    }
    if ($script:Cfg.Profile) {
        $detail = ''
        if ($script:Cfg.ProfileRef) { $detail += ", ref $($script:Cfg.ProfileRef)" }
        if ($script:Cfg.ProfilePath) { $detail += ", path $($script:Cfg.ProfilePath)" }
        Write-PovyDoctorOk "profile $($script:Cfg.Profile)$detail"
    }
    $conf = if (Test-Path -LiteralPath $script:PovyMiseConf) { [System.IO.File]::ReadAllText($script:PovyMiseConf) } else { $null }
    if ($null -eq $conf) {
        Write-PovyDoctorFailure "$script:PovyMiseConf is missing; run: povy apply"
    } elseif ($conf -cne (Get-PovyMiseConfText)) {
        Write-PovyDoctorFailure "$script:PovyMiseConf is outdated; run: povy apply"
    } else {
        $suffix = if ($script:Prof.Team) { ', which includes team.toml from the profile' } else { '' }
        Write-PovyDoctorOk "mise config: $script:PovyMiseConf$suffix"
    }
    if ($script:Prof.Bin) {
        if (Test-PovyOnUserPath $script:Prof.Bin) {
            Write-PovyDoctorOk "profile commands on the user PATH: $($script:Prof.Bin)"
        } else {
            Write-PovyDoctorFailure "the profile commands in $($script:Prof.Bin) are not on the user PATH; run: povy apply"
        }
    }
    if (-not $script:Prof.Project) { return }
    try {
        $names = @(Get-PovySecretName)
    } catch {
        Write-PovyDoctorFailure $_.Exception.Message
        return
    }
    $missing = @(Get-PovySecretMissing $names)
    if ($missing.Count -gt 0) {
        Write-PovyDoctorFailure "empty secrets in ${script:PovyEnvFile}: $($missing -join ' ')"
    } elseif ($names.Count -gt 0) {
        Write-PovyDoctorOk 'the secrets the profile needs are set'
    }
    $null = Invoke-PovyMiseWithSecret $names @('bootstrap', 'status', '--missing', '-C', $script:PovyProfileRoot) 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-PovyDoctorOk "mise bootstrap: the profile's mise.toml is applied"
    } else {
        Write-PovyDoctorFailure "the profile's mise.toml is not fully applied; run: povy apply, or see: mise bootstrap status -C $($script:PovyProfileRoot)"
    }
    if (-not $IsWindows) { return }
    foreach ($file in $script:Prof.WindowsFiles) {
        if (-not (Test-Path -LiteralPath $file.Path -PathType Leaf)) {
            Write-PovyDoctorFailure "$($file.Path) is missing; run: povy apply"
        } elseif ($file.Private -and -not (Test-PovyPrivate $file.Path)) {
            Write-PovyDoctorFailure "$($file.Path) is readable by others; run: povy apply"
        } else {
            Write-PovyDoctorOk "$($file.Path) is in place"
        }
    }
}

# Compares the generated Git files with what apply would write now, as the bash
# engine does.
function Test-PovyDoctorGit {
    $global = Get-PovyGitGlobalFile
    if ((Test-Path -LiteralPath $global) -and ([System.IO.File]::ReadAllLines($global) -ccontains (Get-PovyBlockMarker ''))) {
        Write-PovyDoctorOk "povy block in $global"
    } else {
        Write-PovyDoctorFailure "no povy block in $global; run: povy apply"
        return
    }
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ('povy-git.' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    try {
        if (-not (Write-PovyGitConfig $stage)) {
            Write-PovyDoctorFailure 'could not generate the Git configuration'
            return
        }
        $stale = $false
        foreach ($file in Get-ChildItem -LiteralPath $stage -File) {
            $current = Join-Path $script:PovyGitDir $file.Name
            if (-not (Test-Path -LiteralPath $current) -or -not (Test-PovySameContent $file.FullName $current)) { $stale = $true }
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $script:PovyGitDir -Filter 'identity-*' -File -ErrorAction Ignore)) {
            if (-not (Test-Path -LiteralPath (Join-Path $stage $file.Name))) { $stale = $true }
        }
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Ignore
    }
    if ($stale) {
        Write-PovyDoctorFailure "$script:PovyGitDir does not match config.toml; run: povy apply"
        return
    }
    Write-PovyDoctorOk "Git identity $($script:Cfg.Email), and $(@($script:Cfg.Identities).Count) by directory"
    $overriding = @(Get-PovyGitOverridingFile)
    if ($overriding.Count -gt 0) {
        Write-PovyDoctorWarning "set after the povy include, user.name or user.email overrides it in: $($overriding -join ' ')"
    }
}

function Invoke-PovyDoctor {
    Initialize-PovyPath
    $mise = Get-PovyMise
    if (-not $mise) {
        Write-PovyDoctorFailure 'mise is not installed'
    } elseif (-not (Test-PovyMiseRecent)) {
        Write-PovyDoctorFailure "mise is older than $($script:PovyMiseMin); update it with winget, or with: mise self-update"
    } else {
        Write-PovyDoctorOk "mise $((Invoke-PovyMise --version | Select-Object -First 1))"
    }
    if ($mise -and (Get-PovyYq)) {
        Write-PovyDoctorOk "$script:PovyYqTool available"
    } else {
        Write-PovyDoctorFailure "$script:PovyYqTool is not installed; run: povy init"
    }
    $configOk = $false
    if (Get-PovyYq) {
        try {
            Import-PovyConfig
            $configOk = $true
            Write-PovyDoctorOk "$script:PovyConfigFile is valid"
        } catch {
            Write-PovyDoctorFailure $_.Exception.Message
        }
    }
    if ($configOk) {
        Test-PovyDoctorProfile
        Test-PovyDoctorGit
    }
    if (-not (Test-Path -LiteralPath $script:PovyEnvFile)) {
        Write-PovyDoctorFailure "$script:PovyEnvFile is missing; run: povy init"
    } elseif (Test-PovyPrivate $script:PovyEnvFile) {
        Write-PovyDoctorOk "$script:PovyEnvFile is private"
    } else {
        Write-PovyDoctorFailure "$script:PovyEnvFile is readable by others; run: povy apply"
    }
    if ((Test-Path -LiteralPath $script:PovyPsProfile) -and ([System.IO.File]::ReadAllLines($script:PovyPsProfile) -ccontains (Get-PovyBlockMarker ''))) {
        Write-PovyDoctorOk "povy block in $script:PovyPsProfile"
    } else {
        Write-PovyDoctorFailure "no povy block in $script:PovyPsProfile; run: povy apply"
    }
    if (Test-PovyOnUserPath $script:PovyShimsDir) {
        Write-PovyDoctorOk 'the mise shims are on the user PATH, for every new process'
    } else {
        Write-PovyDoctorFailure 'the mise shims are not on the user PATH; run: povy apply'
    }
    $miseDir = Get-PovyMissingMiseDir
    if ($miseDir -and -not (Test-PovyOnUserPath $miseDir)) {
        Write-PovyDoctorFailure "mise is not on the PATH of new processes, so its shims fail there; run: povy apply"
    } elseif ($IsWindows -and $mise) {
        Write-PovyDoctorOk 'mise is on the PATH of new processes, for its shims'
    }
    if ($configOk) { Test-PovyShadowedShim }
    if ($script:DoctorFailed) {
        Write-Output 'povy doctor found problems.'
    } else {
        Write-Output 'povy doctor: all good.'
    }
}

# Commands write their results to the output stream, so the exit code goes through
# $script:PovyExitCode instead of a return value.
function Invoke-Povy([string[]]$Arguments) {
    $script:PovyExitCode = 0
    $command = if ($Arguments.Count -gt 0) { $Arguments[0] } else { 'help' }
    $rest = if ($Arguments.Count -gt 1) { $Arguments[1..($Arguments.Count - 1)] } else { @() }
    switch -CaseSensitive ($command) {
        'init' { Invoke-PovyInit $rest }
        'apply' { Invoke-PovyApply }
        'doctor' {
            Invoke-PovyDoctor
            if ($script:DoctorFailed) { $script:PovyExitCode = 1 }
        }
        { $_ -in 'version', '-V', '--version' } { Write-Output "povy $(Get-PovyVersion)" }
        { $_ -in 'help', '-h', '--help' } { Show-PovyUsage }
        default {
            [Console]::Error.WriteLine((Show-PovyUsage))
            Stop-Povy "unknown command: $command"
        }
    }
}
