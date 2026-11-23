# povy init, apply and doctor of the PowerShell engine, run as a user would, in a
# sandbox, with mise for real. Outside Windows, mise bootstrap writes the files of the
# test profile itself; System.Tests.ps1 checks the renderer that writes them on Windows.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares the variables of BeforeAll and BeforeEach with the It blocks')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helper.ps1')
    $fixture = Join-Path $script:PovyRoot 'tests/fixtures/profile'
}

# One init and one apply serve every check of this block: each It reads their result,
# and those that run povy again leave the state as they found it.
Describe 'povy init, apply and doctor with the test profile' {
    BeforeAll {
        $sandbox = New-PovySandbox
        $profileRepo = Join-Path $sandbox.Root 'profile'
        $config = Join-Path $sandbox.Root 'config.toml'
        New-PovyProfileRepo $profileRepo
        Write-PovyTestConfig $config $profileRepo "`n[[identities]]`ndir = `"~/oss/`"`nemail = `"oss@example.org`""
        # Where the bootstrap installs the povy command, which goes last on the PATH.
        New-Item -ItemType Directory -Force -Path $sandbox.Launcher | Out-Null
        $init = Invoke-PovyCli init --config $config
        if ($init.Code -ne 0) { throw "povy init failed: $($init.Output)" }
        $envAfterInit = @(Get-Content -LiteralPath $sandbox.EnvFile)
        Add-Content -LiteralPath $sandbox.EnvFile -Value 'EXAMPLE_API_TOKEN=s3cr3t'
        $apply = Invoke-PovyCli apply
        if ($apply.Code -ne 0) { throw "povy apply failed: $($apply.Output)" }
    }
    AfterAll {
        Remove-PovySandbox $sandbox
    }

    It 'adds a line to .env for the secret that the profile reads' {
        $init.Output | Should -Match '(?m)^EXAMPLE_API_TOKEN$'
        $envAfterInit | Should -Contain 'EXAMPLE_API_TOKEN='
    }

    It 'keeps config.toml and .env for the owner alone' {
        Test-PovyOwnerOnly (Join-Path $sandbox.Home '.config/povy/config.toml') | Should -BeTrue
        Test-PovyOwnerOnly $sandbox.EnvFile | Should -BeTrue
    }

    It 'has mise include the team.toml of the profile in every directory' {
        $conf = Get-Content -LiteralPath (Join-Path $sandbox.Home '.config/mise/conf.d/povy.toml')
        $team = [IO.Path]::GetFullPath((Join-Path $sandbox.Clone 'team.toml')).Replace('\', '/')
        $conf | Should -Contain "include = [`"$team`"]"
        $conf | Should -Contain '"yq" = "4"'
    }

    It 'puts the shims, the profile commands, ~/.local/bin and the povy command first on the user PATH' {
        $entries = @((Get-Content -Raw -LiteralPath $sandbox.UserPath).Trim() -split ';' |
                ForEach-Object { [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($_)) })
        $wanted = @($sandbox.Shims, (Join-Path $sandbox.Clone 'bin'), (Join-Path $sandbox.Home '.local/bin'), $sandbox.Launcher)
        $entries[0..3] | Should -Be @($wanted | ForEach-Object { [IO.Path]::GetFullPath($_) })
        # On Windows, the directory of mise follows when the system PATH lacks it.
        $entries.Count | Should -BeIn @(4, 5)
        if ($entries.Count -eq 5) {
            $IsWindows | Should -BeTrue
            $mise = (Get-Command mise -CommandType Application | Select-Object -First 1).Source
            $entries[4] | Should -Be ([IO.Path]::GetFullPath((Split-Path -Parent $mise)))
        }
    }

    It 'has interactive PowerShell source the PowerShell files of the profile' {
        Get-Content -LiteralPath $sandbox.PsProfile | Should -Contain '# >>> povy >>>'
        $interactive = Get-Content -Raw -LiteralPath (Join-Path $sandbox.Home '.config/povy/interactive.ps1')
        $example = [IO.Path]::GetFullPath((Join-Path $sandbox.Clone 'shell/example.ps1'))
        $interactive | Should -Match ([regex]::Escape(". '$example'"))
    }

    It 'writes the files of the profile, with the secret, for the owner alone' {
        # povy writes it on Windows, mise bootstrap elsewhere.
        $file = Join-Path $sandbox.Home '.config/povy-example/example.conf'
        Get-Content -LiteralPath $file | Should -Contain 'token = s3cr3t'
        Test-PovyOwnerOnly $file | Should -BeTrue
    }

    It 'sets the Git identity, and the one of each directory' {
        Get-Content -LiteralPath (Join-Path $sandbox.Home '.gitconfig') | Should -Contain "`tpath = ~/.config/povy/git/config"
        git config --file (Join-Path $sandbox.Home '.config/povy/git/config') 'includeIf.gitdir/i:~/oss/.path' | Should -Be 'identity-1'
    }

    It 'writes nothing on a second apply' {
        $again = Invoke-PovyCli apply
        $again.Code | Should -Be 0 -Because $again.Output
        $again.Output | Should -Match 'Applied: 0 written'
    }

    It 'finds all good with doctor' {
        $doctor = Invoke-PovyCli doctor
        $doctor.Output | Should -Match 'povy doctor: all good'
        $doctor.Code | Should -Be 0 -Because $doctor.Output
        $doctor.Output | Should -Match 'mise config: .*, which includes team\.toml from the profile'
        $doctor.Output | Should -Match "mise bootstrap: the profile's mise\.toml is applied"
    }

    It 'gives a new PowerShell session the functions, the commands and the tools of the profile' {
        # From the home: under the povy checkout, the shims would refuse its mise.toml,
        # which this sandbox does not trust.
        $command = ". '$($sandbox.PsProfile)'; example_greet Ada; example-hello; (Get-Command jq).Source; jq --version"
        $session = @(& $script:Pwsh -NoProfile -WorkingDirectory $sandbox.Home -Command $command 2>&1 | ForEach-Object { "$_" })
        $session[0] | Should -BeExactly 'hello, Ada'
        $session[1] | Should -BeExactly 'hello from the example profile'
        $session[2] | Should -BeLike (Join-Path $sandbox.Shims 'jq*')
        $session[3] | Should -BeExactly 'jq-1.7.1'
    }
}

Describe 'povy apply with a secret left empty' {
    BeforeEach {
        $sandbox = New-PovySandbox
        $profileRepo = Join-Path $sandbox.Root 'profile'
        $config = Join-Path $sandbox.Root 'config.toml'
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'stops before anything is written in the home' {
        New-PovyProfileRepo $profileRepo
        Write-PovyTestConfig $config $profileRepo
        (Invoke-PovyCli init --config $config).Code | Should -Be 0
        $before = Get-PovyHomeState $sandbox

        $run = Invoke-PovyCli apply
        $run.Code | Should -Be 1
        $run.Output | Should -Match '(?m)^error: '
        $run.Output | Should -Match 'EXAMPLE_API_TOKEN'
        $changes = Compare-Object $before (Get-PovyHomeState $sandbox) | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }
        $changes | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $sandbox.Home '.config/mise/conf.d/povy.toml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $sandbox.Home '.config/povy-example') | Should -BeFalse
        Test-Path -LiteralPath $sandbox.PsProfile | Should -BeFalse
        Test-Path -LiteralPath $sandbox.UserPath | Should -BeFalse
    }
}

Describe 'profile_ref' {
    BeforeAll {
        # Commits a new team.toml on a branch of the repository, and returns the commit.
        function Add-PovyProfileCommit([string]$Repo, [string]$Branch, [string]$Text) {
            git -C $Repo checkout --quiet $Branch
            Write-PovyTestFile (Join-Path $Repo 'team.toml') $Text
            git -C $Repo -c user.name=t -c user.email=t@example.org commit --quiet -am $Text
            git -C $Repo checkout --quiet main
            return (git -C $Repo rev-parse "refs/heads/$Branch")
        }
    }
    BeforeEach {
        $sandbox = New-PovySandbox
        $profileRepo = Join-Path $sandbox.Root 'profile'
        $url = $profileRepo.Replace('\', '/')
        $config = Join-Path $sandbox.Root 'config.toml'
        # The tag v1 and the branch main are on the first commit, alt is one ahead.
        New-PovyCustomProfile $profileRepo -Team '# first'
        $first = git -C $profileRepo rev-parse HEAD
        git -C $profileRepo tag v1
        git -C $profileRepo branch alt
        $alt = Add-PovyProfileCommit $profileRepo alt '# on alt'
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'checks out a branch, follows it at each apply, and leaves it when the ref goes' {
        Write-PovyTestConfig $config $profileRepo 'profile_ref = "alt"'
        (Invoke-PovyCli init --config $config).Code | Should -Be 0
        git -C $sandbox.Clone rev-parse HEAD | Should -Be $alt
        git -C $sandbox.Clone symbolic-ref --short HEAD | Should -Be 'alt'

        $next = Add-PovyProfileCommit $profileRepo alt '# next on alt'
        $run = Invoke-PovyCli apply
        $run.Code | Should -Be 0 -Because $run.Output
        git -C $sandbox.Clone rev-parse HEAD | Should -Be $next

        Write-PovyTestConfig $config $profileRepo
        (Invoke-PovyCli init --config $config).Code | Should -Be 0
        git -C $sandbox.Clone rev-parse HEAD | Should -Be $first
        git -C $sandbox.Clone symbolic-ref --short HEAD | Should -Be 'main'
    }

    It 'checks out a tag, and looks it up again when it moves' {
        Write-PovyTestConfig $config $profileRepo 'profile_ref = "v1"'
        (Invoke-PovyCli init --config $config).Code | Should -Be 0
        git -C $sandbox.Clone rev-parse HEAD | Should -Be $first

        git -C $profileRepo tag --force v1 $alt
        $run = Invoke-PovyCli apply
        $run.Code | Should -Be 0 -Because $run.Output
        git -C $sandbox.Clone rev-parse HEAD | Should -Be $alt
    }

    It 'stays on a commit' {
        Write-PovyTestConfig $config $profileRepo "profile_ref = `"$first`""
        (Invoke-PovyCli init --config $config).Code | Should -Be 0
        git -C $sandbox.Clone rev-parse HEAD | Should -Be $first

        Add-PovyProfileCommit $profileRepo main '# next on main' | Out-Null
        $run = Invoke-PovyCli apply
        $run.Code | Should -Be 0 -Because $run.Output
        git -C $sandbox.Clone rev-parse HEAD | Should -Be $first
    }

    It 'takes profile_branch as the old name of profile_ref' {
        Write-PovyTestConfig $config $profileRepo 'profile_branch = "alt"'
        (Invoke-PovyCli init --config $config).Code | Should -Be 0
        git -C $sandbox.Clone rev-parse HEAD | Should -Be $alt
        (Invoke-PovyCli doctor).Output | Should -Match ([regex]::Escape("[ok]   profile $url, ref alt"))
    }

    It 'refuses profile_ref and profile_branch together' {
        Write-PovyTestConfig $config $profileRepo "profile_ref = `"alt`"`nprofile_branch = `"alt`""
        $run = Invoke-PovyCli init --config $config
        $run.Code | Should -Be 1
        $run.Output | Should -Match 'config\.toml: set profile_ref only, profile_branch is its old name'
    }

    It 'stops init at a ref that the profile does not have' {
        Write-PovyTestConfig $config $profileRepo 'profile_ref = "nope"'
        $run = Invoke-PovyCli init --config $config
        $run.Code | Should -Be 1
        $run.Output | Should -Match ([regex]::Escape("error: could not clone the profile: $url, ref nope"))
        Test-Path -LiteralPath $sandbox.Clone | Should -BeFalse
    }

    It 'refuses <Value> as profile_ref' -ForEach @(
        @{ Value = '"-x"'; Message = 'invalid profile_ref: -x' }
        @{ Value = '"a b"'; Message = 'invalid profile_ref: a b' }
        @{ Value = '"a..b"'; Message = 'invalid profile_ref: a..b' }
        @{ Value = '3'; Message = 'profile_ref must be a string' }
    ) {
        Write-PovyTestConfig $config $profileRepo "profile_ref = $Value"
        $run = Invoke-PovyCli init --config $config
        $run.Code | Should -Be 1 -Because "accepted: $Value"
        $run.Output | Should -Match ('config\.toml: ' + [regex]::Escape($Message))
    }

    It 'refuses profile_ref without a profile' {
        Write-PovyTestConfig $config '' 'profile_ref = "alt"'
        $run = Invoke-PovyCli init --config $config
        $run.Code | Should -Be 1
        $run.Output | Should -Match 'config\.toml: profile_ref needs a profile'
    }
}

Describe 'what povy 0.1 read' {
    BeforeEach {
        $sandbox = New-PovySandbox
        $profileRepo = Join-Path $sandbox.Root 'profile'
        $config = Join-Path $sandbox.Root 'config.toml'
        $wayOut = ': since povy 0.2, tools, packages and the prompt are mise configuration; move them to ~/.config/mise/config.toml or to the profile''s team.toml and mise.toml'
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'refuses <Key> in config.toml, and gives the way out' -ForEach @(
        @{ Key = 'tools'; Extra = "[tools]`njq = `"1.7.1`"" }
        @{ Key = 'packages'; Extra = "[packages]`nbrew = [`"tree`"]" }
        @{ Key = 'prompt'; Extra = 'prompt = "starship"' }
        @{ Key = 'tools packages prompt'; Extra = "prompt = `"starship`"`n[tools]`njq = `"1.7.1`"`n[packages]`nbrew = [`"tree`"]" }
    ) {
        Write-PovyTestConfig $config '' $Extra
        $run = Invoke-PovyCli init --config $config
        $run.Code | Should -Be 1
        $run.Output | Should -Match ('(?m)^error: .*config\.toml: ' + [regex]::Escape($Key + $wayOut))
        Test-Path -LiteralPath (Join-Path $sandbox.Home '.config/povy/config.toml') | Should -BeFalse
    }

    It 'stops apply, and fails doctor, on a config.toml that povy 0.1 wrote' {
        $file = Join-Path $sandbox.Home '.config/povy/config.toml'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
        Write-PovyTestConfig $file '' 'prompt = "starship"'
        $run = Invoke-PovyCli apply
        $run.Code | Should -Be 1
        $run.Output | Should -Match ([regex]::Escape('config.toml: prompt' + $wayOut))
        $doctor = Invoke-PovyCli doctor
        $doctor.Code | Should -Be 1
        $doctor.Output | Should -Match ('\[FAIL\] .*' + [regex]::Escape('config.toml: prompt' + $wayOut))
    }

    It 'refuses a profile in the povy 0.1 format' {
        New-PovyCustomProfile $profileRepo -Files @{ 'profile.toml' = "[tools]`njq = `"1.7.1`"" }
        Write-PovyTestConfig $config $profileRepo
        $run = Invoke-PovyCli init --config $config
        $run.Code | Should -Be 1
        $run.Output | Should -Match ([regex]::Escape('the profile is in the povy 0.1 format, profile.toml; convert it to team.toml and mise.toml, as _samples/profile shows'))
    }

    It 'refuses a repository with neither team.toml nor mise.toml' {
        New-PovyCustomProfile $profileRepo -Files @{ 'README.md' = '# not a profile' }
        Write-PovyTestConfig $config $profileRepo
        $run = Invoke-PovyCli init --config $config
        $run.Code | Should -Be 1
        $run.Output | Should -Match ([regex]::Escape("the profile has neither team.toml nor mise.toml: $($profileRepo.Replace('\', '/'))"))
    }
}

Describe 'profile_path' {
    BeforeEach {
        $sandbox = New-PovySandbox
        $profileRepo = Join-Path $sandbox.Root 'profile'
        $url = $profileRepo.Replace('\', '/')
        $config = Join-Path $sandbox.Root 'config.toml'
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'reads the profile from a directory of its repository' {
        New-Item -ItemType Directory -Force -Path (Join-Path $profileRepo 'nested') | Out-Null
        Copy-Item -LiteralPath $fixture -Destination (Join-Path $profileRepo 'nested/profile') -Recurse
        Initialize-PovyGitRepo $profileRepo
        Write-PovyTestConfig $config $profileRepo 'profile_path = "nested/profile/"'
        (Invoke-PovyCli init --config $config).Code | Should -Be 0
        Add-Content -LiteralPath $sandbox.EnvFile -Value 'EXAMPLE_API_TOKEN=nested'

        $run = Invoke-PovyCli apply
        $run.Code | Should -Be 0 -Because $run.Output
        Get-Content -LiteralPath (Join-Path $sandbox.Home '.config/povy-example/example.conf') | Should -Contain 'token = nested'
        $team = [IO.Path]::GetFullPath((Join-Path $sandbox.Clone 'nested/profile/team.toml')).Replace('\', '/')
        Get-Content -LiteralPath (Join-Path $sandbox.Home '.config/mise/conf.d/povy.toml') | Should -Contain "include = [`"$team`"]"

        $doctor = Invoke-PovyCli doctor
        $doctor.Code | Should -Be 0 -Because $doctor.Output
        $doctor.Output | Should -Match ([regex]::Escape("[ok]   profile $url, path nested/profile"))
        $bin = [IO.Path]::GetFullPath((Join-Path $sandbox.Clone 'nested/profile/bin'))
        $doctor.Output | Should -Match ([regex]::Escape("[ok]   profile commands on the user PATH: $bin"))
    }

    It 'refuses <Value> as profile_path' -ForEach @(
        @{ Value = '"../outside"'; Message = 'invalid profile_path: ../outside' }
        @{ Value = '"/abs"'; Message = 'invalid profile_path: /abs' }
        @{ Value = '"a/../b"'; Message = 'invalid profile_path: a/../b' }
        @{ Value = '3'; Message = 'profile_path must be a string' }
        @{ Value = '"missing"'; Message = 'the profile repository has no directory missing' }
        @{ Value = '"empty"'; Message = 'the profile has neither team.toml nor mise.toml' }
    ) {
        New-PovyCustomProfile $profileRepo -Team '# root' -Files @{ 'empty/README.md' = '# no profile here' }
        Write-PovyTestConfig $config $profileRepo "profile_path = $Value"
        $run = Invoke-PovyCli init --config $config
        $run.Code | Should -Be 1 -Because "accepted: $Value"
        $run.Output | Should -Match ('(?m)^error: .*' + [regex]::Escape($Message))
    }

    # Git for Windows checks a link out as a plain file, unless core.symlinks is set.
    It 'refuses a directory that leaves the repository through a link' -Skip:$IsWindows {
        $outside = Join-Path $sandbox.Root 'outside'
        Write-PovyTestFile (Join-Path $outside 'team.toml') '# outside'
        New-PovyCustomProfile $profileRepo -Team '# root'
        New-Item -ItemType SymbolicLink -Path (Join-Path $profileRepo 'escape') -Target $outside | Out-Null
        Initialize-PovyGitRepo $profileRepo
        Write-PovyTestConfig $config $profileRepo 'profile_path = "escape"'
        $run = Invoke-PovyCli init --config $config
        $run.Code | Should -Be 1
        $run.Output | Should -Match 'error: profile_path is outside the profile: escape'
    }

    It 'refuses profile_path without a profile' {
        Write-PovyTestConfig $config '' 'profile_path = "x"'
        $run = Invoke-PovyCli init --config $config
        $run.Code | Should -Be 1
        $run.Output | Should -Match 'config\.toml: profile_path needs a profile'
    }
}

Describe 'the [_.povy] table of mise.toml' {
    BeforeEach {
        $sandbox = New-PovySandbox
        $profileRepo = Join-Path $sandbox.Root 'profile'
        $config = Join-Path $sandbox.Root 'config.toml'
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'a bin outside the profile'; Body = "[_.povy]`nbin = `"../outside`""; Message = 'invalid _.povy.bin: ../outside' }
        @{ Case = 'a bin that is not a directory'; Body = "[_.povy]`nbin = `"missing`""; Message = '_.povy.bin is not a directory of the profile: missing' }
        @{ Case = 'a bin that is not a string'; Body = "[_.povy]`nbin = 3"; Message = 'bin must be a string' }
        @{ Case = 'a _.povy that is not a table'; Body = "[_]`npovy = 1"; Message = 'povy must be a table: [_.povy]' }
        @{ Case = 'a windows that is not a table'; Body = "[_.povy]`nwindows = 1"; Message = 'windows must be a table: [_.povy.windows]' }
        @{ Case = 'files that are not a list'; Body = "[_.povy.windows]`nfiles = `"~/.x`""; Message = '_.povy.windows.files must be a list of targets' }
        @{ Case = 'a file that [bootstrap.files] does not declare'; Body = "[_.povy.windows]`nfiles = [`"~/.x`"]"; Message = '_.povy.windows.files names ~/.x, which [bootstrap.files] does not declare' }
        @{ Case = 'a file that is a block'; Body = "[bootstrap.files.`"~/.x`"]`nos = `"unix`"`nblock = `"x`"`n[_.povy.windows]`nfiles = [`"~/.x`"]"; Message = 'povy writes whole files on Windows, without block: ~/.x' }
        @{ Case = 'shell files that are not a list'; Body = "[_.povy.windows]`nshell = `"shell/x.ps1`""; Message = '_.povy.windows.shell must be a list of files' }
        @{ Case = 'a shell file that is not PowerShell'; Body = "[_.povy.windows]`nshell = [`"shell/x.sh`"]"; Message = '_.povy.windows.shell takes .ps1 files of the profile: shell/x.sh' }
        @{ Case = 'a shell file outside the profile'; Body = "[_.povy.windows]`nshell = [`"../x.ps1`"]"; Message = '_.povy.windows.shell takes .ps1 files of the profile: ../x.ps1' }
        @{ Case = 'a shell file that is missing'; Body = "[_.povy.windows]`nshell = [`"shell/missing.ps1`"]"; Message = 'profile file not found: shell/missing.ps1' }
    ) {
        New-PovyCustomProfile $profileRepo -Project $Body
        Write-PovyTestConfig $config $profileRepo
        $run = Invoke-PovyCli init --config $config
        $run.Code | Should -Be 1 -Because "accepted: $Body"
        $run.Output | Should -Match ('(?m)^error: .*mise\.toml: ' + [regex]::Escape($Message))
    }
}

Describe 'the sample profile' {
    BeforeAll {
        $sandbox = New-PovySandbox
        $repo = Join-Path $sandbox.Root 'repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo '_samples') | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:PovyRoot '_samples/profile') -Destination (Join-Path $repo '_samples') -Recurse
        Initialize-PovyGitRepo $repo
        $config = Join-Path $sandbox.Root 'config.toml'
        Write-PovyTestConfig $config $repo 'profile_path = "_samples/profile"'
        # init only: apply would install the package of the sample on this machine.
        $init = Invoke-PovyCli init --config $config
    }
    AfterAll {
        Remove-PovySandbox $sandbox
    }

    It 'passes init, from the directory its README gives' {
        $init.Code | Should -Be 0 -Because $init.Output
    }

    It 'adds a line to .env for the secret that it reads' {
        Get-Content -LiteralPath $sandbox.EnvFile | Should -Contain 'SAMPLE_API_TOKEN='
    }
}

Describe 'a team.toml that mise cannot read' {
    BeforeAll {
        $sandbox = New-PovySandbox
        $profileRepo = Join-Path $sandbox.Root 'profile'
        $config = Join-Path $sandbox.Root 'config.toml'
        New-PovyCustomProfile $profileRepo -Team "[env]`nTEAM = `"v1`""
        Write-PovyTestConfig $config $profileRepo
        New-Item -ItemType Directory -Force -Path $sandbox.Launcher | Out-Null
        $init = Invoke-PovyCli init --config $config
        if ($init.Code -ne 0) { throw "povy init failed: $($init.Output)" }
        $apply = Invoke-PovyCli apply
        if ($apply.Code -ne 0) { throw "povy apply failed: $($apply.Output)" }
    }
    AfterAll {
        Remove-PovySandbox $sandbox
    }

    It 'stops apply, and the next apply still takes the fix' {
        Write-PovyTestFile (Join-Path $profileRepo 'team.toml') "[env`nTEAM = `"v2`""
        Add-PovyGitCommit $profileRepo
        (Invoke-PovyCli apply).Code | Should -Not -Be 0
        Write-PovyTestFile (Join-Path $profileRepo 'team.toml') "[env]`nTEAM = `"v3`""
        Add-PovyGitCommit $profileRepo
        $apply = Invoke-PovyCli apply
        $apply.Code | Should -Be 0 -Because $apply.Output
        Get-Content -LiteralPath (Join-Path $sandbox.Clone 'team.toml') | Should -Contain 'TEAM = "v3"'
    }
}
