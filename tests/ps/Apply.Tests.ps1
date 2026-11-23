# povy init, apply and doctor on Windows, run as a user would, in a sandbox.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares the variables of BeforeAll and BeforeEach with the It blocks')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helper.ps1')
}

Describe 'povy apply' {
    BeforeEach {
        $sandbox = New-PovySandbox
        $profileRepo = Join-Path $sandbox.Root 'profile'
        $config = Join-Path $sandbox.Root 'config.toml'
        $envFile = Join-Path $sandbox.Home '.config/povy/.env'
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'sets up tools, PATH, PowerShell profile, Git identity and files, then changes nothing' {
        New-PovyProfileRepo $profileRepo
        Write-PovyTestConfig $config $profileRepo "`n[[identities]]`ndir = `"~/oss/`"`nemail = `"oss@example.org`""
        (Invoke-PovyCli init --config $config).Code | Should -Be 0
        Add-Content -LiteralPath $envFile -Value 'EXAMPLE_API_TOKEN=s3cr3t'

        $run = Invoke-PovyCli apply
        $run.Code | Should -Be 0 -Because $run.Output

        $rendered = Join-Path $sandbox.Home '.config/povy-example/example.conf'
        Get-Content -LiteralPath $rendered | Should -Contain 'token = s3cr3t'
        (Get-Content -LiteralPath (Join-Path $sandbox.Home '.config/mise/conf.d/povy.toml')) | Should -Contain '"jq" = "1.7.1"'
        $entries = @((Get-Content -Raw -LiteralPath $sandbox.UserPath).Trim() -split ';' |
                ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) })
        $state = if ($IsWindows) { Join-Path $sandbox.Local 'povy/state' } else { Join-Path $sandbox.Home '.local/state/povy' }
        $entries[0] | Should -Be ([IO.Path]::GetFullPath((Join-Path $env:MISE_DATA_DIR 'shims')))
        $entries[1] | Should -Be ([IO.Path]::GetFullPath((Join-Path $state 'profile/bin')))
        Get-Content -LiteralPath $sandbox.PsProfile | Should -Contain '# >>> povy >>>'
        $interactive = Get-Content -Raw -LiteralPath (Join-Path $sandbox.Home '.config/povy/interactive.ps1')
        $interactive | Should -Match 'example\.ps1'
        $interactive | Should -Not -Match 'example\.sh'
        Get-Content -LiteralPath (Join-Path $sandbox.Home '.gitconfig') | Should -Contain "`tpath = ~/.config/povy/git/config"
        git config --file (Join-Path $sandbox.Home '.config/povy/git/config') 'includeIf.gitdir/i:~/oss/.path' | Should -Be 'identity-1'

        $again = Invoke-PovyCli apply
        $again.Code | Should -Be 0
        $again.Output | Should -Match 'Applied: 0 written'

        $doctor = Invoke-PovyCli doctor
        $doctor.Output | Should -Match 'povy doctor: all good'
        $doctor.Code | Should -Be 0 -Because $doctor.Output
    }

    It 'loads the profile functions and puts the tools first in a PowerShell session' {
        New-PovyProfileRepo $profileRepo
        Write-PovyTestConfig $config $profileRepo
        (Invoke-PovyCli init --config $config).Code | Should -Be 0
        Add-Content -LiteralPath $envFile -Value 'EXAMPLE_API_TOKEN=x'
        (Invoke-PovyCli apply).Code | Should -Be 0

        $session = & $script:Pwsh -NoProfile -Command ". '$($sandbox.PsProfile)'; example_greet Ada; (Get-Command jq).Source"
        $session[0] | Should -Be 'hello, Ada'
        $session[1] | Should -BeLike (Join-Path $env:MISE_DATA_DIR 'shims*')
    }

    It 'refuses empty secrets and writes nothing in the home' {
        New-PovyProfileRepo $profileRepo
        Write-PovyTestConfig $config $profileRepo
        (Invoke-PovyCli init --config $config).Code | Should -Be 0
        $run = Invoke-PovyCli apply
        $run.Code | Should -Be 1
        $run.Output | Should -Match 'EXAMPLE_API_TOKEN'
        Test-Path -LiteralPath $sandbox.PsProfile | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $sandbox.Home '.gitconfig') | Should -BeFalse
        Test-Path -LiteralPath $sandbox.UserPath | Should -BeFalse
    }

    It 'stops at an unknown placeholder before any file is written' {
        New-PovyCustomProfile $profileRepo "[[files]]`nsource = `"files/bad`"`ntarget = `".out/bad`"" @{ bad = 'value {{NOPE}}' }
        Write-PovyTestConfig $config $profileRepo
        (Invoke-PovyCli init --config $config).Code | Should -Be 0
        $run = Invoke-PovyCli apply
        $run.Code | Should -Be 1
        $run.Output | Should -Match 'unknown placeholder \{\{NOPE\}\}'
        Test-Path -LiteralPath (Join-Path $sandbox.Home '.out/bad') | Should -BeFalse
        Test-Path -LiteralPath $sandbox.PsProfile | Should -BeFalse
    }

    It 'reads a profile from a directory of its repository' {
        New-PovyProfileRepo (Join-Path $profileRepo 'nested/profile')
        Remove-Item -LiteralPath (Join-Path $profileRepo 'nested/profile/.git') -Recurse -Force
        Initialize-PovyGitRepo $profileRepo
        Write-PovyTestConfig $config $profileRepo 'profile_path = "nested/profile"'
        (Invoke-PovyCli init --config $config).Code | Should -Be 0
        Add-Content -LiteralPath $envFile -Value 'EXAMPLE_API_TOKEN=x'
        (Invoke-PovyCli apply).Code | Should -Be 0
        (Invoke-PovyCli doctor).Output | Should -Match 'path nested/profile'
    }

    It 'installs the missing winget packages, and reports the ones that fail' {
        $state = Join-Path $sandbox.Root 'winget-state'
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        Set-Content -LiteralPath (Join-Path $state 'installed') -Value 'Already.There'
        $stub = Join-Path $sandbox.Root 'winget.ps1'
        Set-Content -LiteralPath $stub -Value @"
`$state = '$state'
Add-Content -LiteralPath (Join-Path `$state 'calls') -Value (`$args -join ' ')
`$id = `$args[[array]::IndexOf(`$args, '--id') + 1]
`$installed = @(Get-Content -LiteralPath (Join-Path `$state 'installed'))
if (`$args[0] -eq 'list') { if (`$installed -contains `$id) { exit 0 }; exit 1 }
if (`$id -eq 'Broken.Tool') { exit 1 }
Add-Content -LiteralPath (Join-Path `$state 'installed') -Value `$id
exit 0
"@
        $env:POVY_WINGET = $stub
        New-PovyCustomProfile $profileRepo "[packages]`nwinget = [`"Already.There`", `"New.Tool`", `"Broken.Tool`"]`nbrew = [`"ignored-here`"]"
        Write-PovyTestConfig $config $profileRepo
        (Invoke-PovyCli init --config $config).Code | Should -Be 0

        $run = Invoke-PovyCli apply
        $run.Code | Should -Be 0 -Because $run.Output
        $run.Output | Should -Match 'could not install with winget: Broken.Tool'
        $calls = Get-Content -LiteralPath (Join-Path $state 'calls')
        $calls | Where-Object { $_ -like 'install*' } | ForEach-Object { ($_ -split ' ')[2] } | Should -Be @('New.Tool', 'Broken.Tool')

        $doctor = Invoke-PovyCli doctor
        $doctor.Code | Should -Be 1
        $doctor.Output | Should -Match '\[FAIL\] packages not installed: Broken.Tool'
    }

    It 'refuses invalid configuration values' -ForEach @(
        @{ Extra = 'profile_path = "../outside"' }
        @{ Extra = "[tools]`njq = `"bad version`"" }
        @{ Extra = "[packages]`npacman = [`"x`"]" }
        @{ Extra = 'prompt = "fish"' }
        @{ Extra = "[[identities]]`ndir = `"relative/`"`nemail = `"a@example.org`"" }
    ) {
        New-PovyProfileRepo $profileRepo
        Write-PovyTestConfig $config $profileRepo $Extra
        $run = Invoke-PovyCli init --config $config
        $run.Code | Should -Be 1 -Because "accepted: $Extra"
        $run.Output | Should -Match '^error: '
    }
}

Describe 'the sample profile' {
    BeforeEach {
        $sandbox = New-PovySandbox
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'is valid for PowerShell, from the directory its README gives' {
        $repo = Join-Path $sandbox.Root 'repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo '_samples') | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:PovyRoot '_samples/profile') -Destination (Join-Path $repo '_samples') -Recurse
        Initialize-PovyGitRepo $repo
        $config = Join-Path $sandbox.Root 'config.toml'
        Write-PovyTestConfig $config $repo 'profile_path = "_samples/profile"'
        $run = Invoke-PovyCli init --config $config
        $run.Code | Should -Be 0 -Because $run.Output
        Get-Content -LiteralPath (Join-Path $sandbox.Home '.config/povy/.env') | Should -Contain 'SAMPLE_API_TOKEN='
    }
}
