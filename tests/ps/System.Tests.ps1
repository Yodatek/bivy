# The building blocks of the PowerShell engine, called directly in a sandbox. apply
# writes the Windows files of a profile on Windows only, and leaves them to mise
# elsewhere, so their renderer is tested here, on every system.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares the variables of BeforeAll and BeforeEach with the It blocks')]
param()

BeforeAll {
    # As bin/povy.ps1 runs the engine.
    Set-StrictMode -Version 3.0
    . (Join-Path $PSScriptRoot 'Helper.ps1')
    foreach ($lib in 'common', 'config', 'profile', 'team', 'system', 'git', 'commands') {
        . (Join-Path $script:PovyRoot "lib/ps/$lib.ps1")
    }
    $fixture = Join-Path $script:PovyRoot 'tests/fixtures/profile'
    $sample = Join-Path $script:PovyRoot '_samples/profile'

    # A sandbox with the paths of povy set in it, and nothing counted yet.
    function Initialize-PovyTestRun {
        $sandbox = New-PovySandbox
        Initialize-PovyPath
        Initialize-PovyDirectory
        $script:PovyWritten = 0
        $script:PovyUnchanged = 0
        $script:PovyBackedUp = 0
        $script:PovyBackupDir = $null
        $script:PovyCreated.Clear()
        $script:Prof = New-PovyProfileState
        $script:PovyProfileRoot = $script:PovyProfileDir
        return $sandbox
    }

    # Puts a profile where povy keeps its clone, and reads it as apply does.
    function Import-PovyTestProfile([string]$From) {
        Copy-Item -LiteralPath $From -Destination $script:PovyProfileDir -Recurse
        Import-PovyProfile 'https://example.org/profile.git' ''
    }
}

Describe 'marked blocks' {
    BeforeEach {
        $sandbox = Initialize-PovyTestRun
        $file = Join-Path $sandbox.Home 'target.ps1'
        $block = "# >>> povy >>>`nnew`n# <<< povy <<<"
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'creates a missing file with the block alone, and does not back it up later' {
        Set-PovyBlock -File $file -Block $block
        Get-Content -LiteralPath $file | Should -Be @('# >>> povy >>>', 'new', '# <<< povy <<<')
        Set-PovyBlock -File $file -Block "# >>> povy interactive >>>`nmore`n# <<< povy interactive <<<" -Position bottom -Name interactive
        $script:PovyBackedUp | Should -Be 0
    }

    It 'puts a top block above the content, which stays byte for byte, then refreshes it in place' {
        [System.IO.File]::WriteAllText($file, "before`nafter`n")
        Set-PovyBlock -File $file -Block $block
        [System.IO.File]::ReadAllText($file) | Should -BeExactly "# >>> povy >>>`nnew`n# <<< povy <<<`nbefore`nafter`n"
        Set-PovyBlock -File $file -Block "# >>> povy >>>`nnewer`n# <<< povy <<<"
        [System.IO.File]::ReadAllText($file) | Should -BeExactly "# >>> povy >>>`nnewer`n# <<< povy <<<`nbefore`nafter`n"
    }

    It 'moves a bottom block to the end, after what the file adds' {
        [System.IO.File]::WriteAllText($file, "one`n# >>> povy >>>`nold`n# <<< povy <<<`ntwo`n")
        Set-PovyBlock -File $file -Block $block -Position bottom
        [System.IO.File]::ReadAllText($file) | Should -BeExactly "one`ntwo`n# >>> povy >>>`nnew`n# <<< povy <<<`n"
    }

    It 'keeps CRLF line endings and a UTF-8 byte order mark' {
        [System.IO.File]::WriteAllText($file, "line`r`n", [System.Text.UTF8Encoding]::new($true))
        Set-PovyBlock -File $file -Block $block -Position bottom
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        [System.IO.File]::ReadAllText($file) | Should -BeExactly "line`r`n# >>> povy >>>`r`nnew`r`n# <<< povy <<<`r`n"
    }

    It 'refuses an incomplete block and leaves the file alone' {
        [System.IO.File]::WriteAllText($file, "keep`n# >>> povy >>>`nmore`n")
        { Set-PovyBlock -File $file -Block $block } | Should -Throw '*incomplete povy block*'
        [System.IO.File]::ReadAllText($file) | Should -BeExactly "keep`n# >>> povy >>>`nmore`n"
    }

    It 'backs up the original once, even when one run changes the file twice' {
        [System.IO.File]::WriteAllText($file, "original`n")
        Set-PovyBlock -File $file -Block $block
        Set-PovyBlock -File $file -Block "# >>> povy x >>>`ny`n# <<< povy x <<<" -Position bottom -Name x
        $script:PovyBackedUp | Should -Be 1
        [System.IO.File]::ReadAllText((Join-Path $script:PovyBackupDir 'target.ps1')) | Should -BeExactly "original`n"
    }
}

Describe 'the user PATH' {
    BeforeEach {
        $sandbox = Initialize-PovyTestRun
        $script:Prof.Bin = [IO.Path]::GetFullPath((Join-Path $script:PovyProfileDir 'bin'))
        New-Item -ItemType Directory -Force -Path $script:PovyLauncherDir | Out-Null
        $other = if ($IsWindows) { 'C:\Other\bin' } else { '/opt/other/bin' }
        $stale = Join-Path $script:PovyDataDir 'state/profile/old-bin'
        $before = "%POVY_TEST_UNSET%\tools;$other;$stale;$($script:PovyShimsDir)"
        [System.IO.File]::WriteAllText($sandbox.UserPath, $before)
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'puts the shims, the profile commands, ~/.local/bin and povy first, and keeps other entries as written' {
        Update-PovyUserPath
        $entries = (Get-Content -Raw -LiteralPath $sandbox.UserPath).Trim() -split ';'
        $expanded = @($entries | ForEach-Object { [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($_)) })
        $expanded[0] | Should -Be ([IO.Path]::GetFullPath($script:PovyShimsDir))
        $expanded[1] | Should -Be $script:Prof.Bin
        $expanded[2] | Should -Be ([IO.Path]::GetFullPath((Join-Path $sandbox.Home '.local/bin')))
        $expanded[3] | Should -Be ([IO.Path]::GetFullPath($script:PovyLauncherDir))
        $entries[4] | Should -BeExactly '%POVY_TEST_UNSET%\tools'
        $entries[5] | Should -Be $other
        # On Windows, mise itself follows when the system PATH lacks it: its shims need it.
        $miseDir = Get-PovyMissingMiseDir
        if ($miseDir) {
            [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($entries[6])) | Should -Be ([IO.Path]::GetFullPath($miseDir))
        }
        $entries.Count | Should -Be (6 + [int][bool]$miseDir)
    }

    It 'backs up the user PATH it replaces' {
        Update-PovyUserPath
        $script:PovyBackedUp | Should -Be 1
        [System.IO.File]::ReadAllText((Join-Path $script:PovyBackupDir 'user-path.txt')) | Should -BeExactly $before
    }

    It 'changes nothing on a second run' {
        Update-PovyUserPath
        $first = Get-Content -Raw -LiteralPath $sandbox.UserPath
        $written = $script:PovyWritten
        Update-PovyUserPath
        Get-Content -Raw -LiteralPath $sandbox.UserPath | Should -BeExactly $first
        $script:PovyWritten | Should -Be $written
    }

    It 'keeps the registry value expandable' -Skip:(-not $IsWindows) {
        $env:POVY_USER_PATH_FILE = $null
        $env:POVY_USER_ENV_KEY = 'Software\povy-tests\Environment'
        try {
            Set-PovyUserPathValue '%USERPROFILE%\bin;C:\Other'
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($env:POVY_USER_ENV_KEY)
            try { $key.GetValueKind('Path') | Should -Be 'ExpandString' } finally { $key.Dispose() }
            Get-PovyUserPathValue | Should -BeExactly '%USERPROFILE%\bin;C:\Other'
        } finally {
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree('Software\povy-tests', $false)
        }
    }
}

Describe '.env and private files' {
    BeforeEach {
        $sandbox = Initialize-PovyTestRun
        Initialize-PovyEnvFile
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'keeps .env private, and reads it as a shell would, without running it' {
        Test-PovyPrivate $script:PovyEnvFile | Should -BeTrue
        Add-Content -LiteralPath $script:PovyEnvFile -Value @('A=first', 'A=second', 'export B="quoted"', "C='single'", "D=crlf`r", 'E=$(rm -rf /)')
        Get-PovyEnvValue 'A' | Should -BeExactly 'second'
        Get-PovyEnvValue 'B' | Should -BeExactly 'quoted'
        Get-PovyEnvValue 'C' | Should -BeExactly 'single'
        Get-PovyEnvValue 'D' | Should -BeExactly 'crlf'
        Get-PovyEnvValue 'E' | Should -BeExactly '$(rm -rf /)'
        Get-PovyEnvValue 'MISSING' | Should -BeNullOrEmpty
    }

    It 'adds an empty line for each missing secret, and lists the empty ones' {
        Add-PovyEnvSeed @('TOKEN', 'OTHER')
        Add-PovyEnvSeed @('TOKEN')
        @(Get-Content -LiteralPath $script:PovyEnvFile | Where-Object { $_ -eq 'TOKEN=' }).Count | Should -Be 1
        @(Get-PovyEnvMissing @('TOKEN', 'OTHER')) | Should -Be @('TOKEN', 'OTHER')
    }

    It 'takes a secret that the environment sets as set' {
        $env:POVY_TEST_FROM_ENV = 'set'
        Add-Content -LiteralPath $script:PovyEnvFile -Value @('POVY_TEST_FROM_FILE=set', 'POVY_TEST_EMPTY=')
        @(Get-PovySecretMissing @('POVY_TEST_FROM_ENV', 'POVY_TEST_FROM_FILE', 'POVY_TEST_EMPTY', 'POVY_TEST_ABSENT')) |
            Should -Be @('POVY_TEST_EMPTY', 'POVY_TEST_ABSENT')
    }

    It 'makes a file private to its owner' {
        $file = Join-Path $sandbox.Root 'secret'
        [System.IO.File]::WriteAllText($file, 'x')
        Set-PovyPrivate $file
        Test-PovyPrivate $file | Should -BeTrue
        Test-PovyOwnerOnly $file | Should -BeTrue
    }
}

Describe 'templates on Windows' {
    BeforeEach {
        $sandbox = Initialize-PovyTestRun
        Initialize-PovyEnvFile
        $script:Prof.Secrets['token'] = 'POVY_TEST_TOKEN'
        $script:Prof.Vars['name'] = 'Ada'
        Add-Content -LiteralPath $script:PovyEnvFile -Value 'POVY_TEST_TOKEN=t0k3n'
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'renders secret() written <Form>' -ForEach @(
        @{ Form = 'with double quotes'; Text = 'token = {{ secret(name="token") }}' }
        @{ Form = 'with single quotes'; Text = "token = {{ secret(name='token') }}" }
        @{ Form = 'without spaces'; Text = 'token = {{secret(name="token")}}' }
        @{ Form = 'with spaces around the name'; Text = 'token = {{ secret( name = "token" ) }}' }
    ) {
        ConvertFrom-PovyTemplate $Text 'label' | Should -BeExactly 'token = t0k3n'
    }

    It 'renders vars' {
        ConvertFrom-PovyTemplate "user = {{ vars.name }}`nagain = {{vars.name}}`n" 'label' | Should -BeExactly "user = Ada`nagain = Ada`n"
    }

    It 'takes a secret from the environment when .env leaves it empty' {
        $script:Prof.Secrets['other'] = 'POVY_TEST_OTHER'
        $env:POVY_TEST_OTHER = 'from-env'
        $env:POVY_TEST_TOKEN = 'not this one'
        ConvertFrom-PovyTemplate '{{ secret(name="other") }} {{ secret(name="token") }}' 'label' | Should -BeExactly 'from-env t0k3n'
    }

    It 'writes a secret as it is, without reading it as a template' {
        Add-Content -LiteralPath $script:PovyEnvFile -Value 'POVY_TEST_TOKEN=a$1\b&c{{ vars.name }}'
        ConvertFrom-PovyTemplate '[{{ secret(name="token") }}]' 'label' | Should -BeExactly '[a$1\b&c{{ vars.name }}]'
    }

    It 'passes text without {{ through unchanged' {
        $text = "plain `$HOME `${HOME} %USERPROFILE% `$1 { braces } }} 100%`r`nnext line`n"
        ConvertFrom-PovyTemplate $text 'label' | Should -BeExactly $text
    }

    It 'stops at <Case>, with a clear message' -ForEach @(
        @{ Case = 'a secret that [bootstrap.secrets] does not declare'; Text = 'x = {{ secret(name="nope") }}'; Message = 'label: the secret nope is not declared in [bootstrap.secrets]' }
        @{ Case = 'a var that [vars] does not declare'; Text = 'x = {{ vars.nope }}'; Message = 'label: vars.nope is not declared in [vars]' }
        @{ Case = 'a statement'; Text = '{% if true %}x{% endif %}'; Message = 'label: povy on Windows renders only secret() and vars in templates' }
        @{ Case = 'a comment'; Text = "{# a note #}`nx"; Message = 'label: povy on Windows renders only secret() and vars in templates' }
        @{ Case = 'another variable'; Text = 'root = {{ config_root }}'; Message = 'label: povy on Windows renders only secret() and vars in templates, not {{ config_root }}' }
        @{ Case = 'a filter'; Text = '{{ vars.name | upper }}'; Message = 'label: povy on Windows renders only secret() and vars in templates, not {{ vars.name | upper }}' }
        @{ Case = 'another function'; Text = '{{ exec(command="whoami") }}'; Message = 'label: povy on Windows renders only secret() and vars in templates, not {{ exec(command="whoami") }}' }
    ) {
        $err = Get-PovyError { ConvertFrom-PovyTemplate $Text 'label' }
        $err.Message | Should -BeExactly $Message
        $err.Data['povy'] | Should -BeTrue
    }

    It 'stops at an empty secret, and names the line to fill' {
        Add-Content -LiteralPath $script:PovyEnvFile -Value 'POVY_TEST_TOKEN='
        $err = Get-PovyError { ConvertFrom-PovyTemplate 'x = {{ secret(name="token") }}' 'label' }
        $err.Message | Should -BeExactly "label: the secret token is empty; fill POVY_TEST_TOKEN in $($script:PovyEnvFile)"
        $err.Data['povy'] | Should -BeTrue
    }

    It 'renders an expression that spans lines, as mise does' {
        ConvertFrom-PovyTemplate "a {{ vars.name`n}} b" 'label' | Should -BeExactly 'a Ada b'
    }

    It 'stops at a {{ left open' {
        (Get-PovyError { ConvertFrom-PovyTemplate 'x = {{ vars.name' 'label' }).Message | Should -BeLike 'label: *'
    }

    It 'matches the names of secrets and vars exactly, as mise does' {
        (Get-PovyError { ConvertFrom-PovyTemplate '{{ secret(name="TOKEN") }}' 'label' }).Message |
            Should -BeExactly 'label: the secret TOKEN is not declared in [bootstrap.secrets]'
        (Get-PovyError { ConvertFrom-PovyTemplate '{{ vars.Name }}' 'label' }).Message |
            Should -BeExactly 'label: vars.Name is not declared in [vars]'
    }
}

Describe 'the files that povy writes on Windows' {
    BeforeEach {
        $sandbox = Initialize-PovyTestRun
        Initialize-PovyEnvFile
        Install-PovyYq
        $script:PovyProfileRoot = Join-Path $sandbox.Root 'profile'
        Write-PovyTestFile (Join-Path $script:PovyProfileRoot 'files/x') 'from the source'
        $label = Join-Path $script:PovyProfileRoot 'mise.toml'
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'takes the content of an entry' {
        $file = ConvertTo-PovyWindowsFile @{ '~/.config/a.conf' = @{ content = "a = 1`n"; os = 'unix' } } '~/.config/a.conf' $label
        $file.Target | Should -BeExactly '~/.config/a.conf'
        $file.Path | Should -BeExactly (Join-Path $script:PovyHome '.config/a.conf')
        $file.Content | Should -BeExactly "a = 1`n"
        $file.Template | Should -BeFalse
        $file.Private | Should -BeFalse
    }

    It 'reads the source of an entry in the profile, written <Source>' -ForEach @(
        @{ Source = './files/x' }
        @{ Source = 'files/x' }
    ) {
        $file = ConvertTo-PovyWindowsFile @{ '~/.x' = @{ source = $Source; template = $true } } '~/.x' $label
        $file.Content | Should -BeExactly "from the source`n"
        $file.Template | Should -BeTrue
    }

    It 'refuses the target <Target>, which is not under ~/' -ForEach @(
        @{ Target = '/etc/povy' }
        @{ Target = 'C:/povy' }
        @{ Target = '.povy' }
        @{ Target = '~' }
        @{ Target = '~/' }
        @{ Target = '~/../povy' }
        @{ Target = '~/a/../../povy' }
        @{ Target = '~/dir/' }
        @{ Target = '~root/povy' }
        @{ Target = '~/a\b' }
    ) {
        $err = Get-PovyError { ConvertTo-PovyWindowsFile @{ $Target = @{ content = 'x' } } $Target $label }
        $err.Message | Should -BeExactly "${label}: povy writes Windows files under ~/ only: $Target"
    }

    It 'refuses an entry with <Key>, since povy writes whole files' -ForEach @(
        @{ Key = 'block' }
        @{ Key = 'owner' }
        @{ Key = 'group' }
        @{ Key = 'id' }
    ) {
        $entry = @{ content = 'x'; $Key = 'y' }
        $err = Get-PovyError { ConvertTo-PovyWindowsFile @{ '~/.x' = $entry } '~/.x' $label }
        $err.Message | Should -BeExactly "${label}: povy writes whole files on Windows, without ${Key}: ~/.x"
    }

    It 'refuses a target that [bootstrap.files] does not declare as a table' {
        $files = @{ '~/.other' = @{ content = 'x' }; '~/.text' = 'not a table' }
        foreach ($target in '~/.x', '~/.text') {
            (Get-PovyError { ConvertTo-PovyWindowsFile $files $target $label }).Message |
                Should -BeExactly "${label}: _.povy.windows.files names $target, which [bootstrap.files] does not declare"
        }
    }

    It 'refuses an entry with both content and source, or neither' {
        foreach ($entry in @{ content = 'x'; source = './files/x' }, @{ mode = '0600' }) {
            (Get-PovyError { ConvertTo-PovyWindowsFile @{ '~/.x' = $entry } '~/.x' $label }).Message |
                Should -BeExactly "${label}: ~/.x needs either content or source"
        }
    }

    It 'refuses the source <Source>' -ForEach @(
        @{ Source = './files/missing'; Message = 'source not found for ~/.x: ./files/missing' }
        @{ Source = '../x'; Message = 'invalid source for ~/.x: ../x' }
        @{ Source = '/etc/hosts'; Message = 'invalid source for ~/.x: /etc/hosts' }
        @{ Source = '~/.ssh/id_ed25519'; Message = 'invalid source for ~/.x: ~/.ssh/id_ed25519' }
    ) {
        $err = Get-PovyError { ConvertTo-PovyWindowsFile @{ '~/.x' = @{ source = $Source } } '~/.x' $label }
        $err.Message | Should -BeExactly "${label}: $Message"
    }

    It 'refuses a source that is a link' {
        $outside = Join-Path $sandbox.Root 'outside'
        Write-PovyTestFile $outside 'not part of the profile'
        try {
            New-Item -ItemType SymbolicLink -Path (Join-Path $script:PovyProfileRoot 'files/link') -Target $outside -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because "this system does not let the tests create links: $($_.Exception.Message)"
        }
        $err = Get-PovyError { ConvertTo-PovyWindowsFile @{ '~/.x' = @{ source = './files/link' } } '~/.x' $label }
        $err.Message | Should -BeExactly "the profile's files/link must be a regular file inside the profile"
    }

    It 'makes the file private with <Name>: <OwnerOnly>' -ForEach @(
        @{ Name = 'mode 0600'; Mode = '0600'; OwnerOnly = $true }
        @{ Name = 'mode 600'; Mode = '600'; OwnerOnly = $true }
        @{ Name = 'mode 0400'; Mode = '0400'; OwnerOnly = $true }
        @{ Name = 'mode 0700'; Mode = '0700'; OwnerOnly = $true }
        @{ Name = 'mode 0640'; Mode = '0640'; OwnerOnly = $false }
        @{ Name = 'mode 0644'; Mode = '0644'; OwnerOnly = $false }
        @{ Name = 'no mode'; Mode = ''; OwnerOnly = $false }
    ) {
        $entry = @{ content = 'x' }
        if ($Mode) { $entry.mode = $Mode }
        (ConvertTo-PovyWindowsFile @{ '~/.x' = $entry } '~/.x' $label).Private | Should -Be $OwnerOnly
    }

    It 'reads the Windows part of the test profile' {
        Import-PovyTestProfile $fixture
        $script:Prof.Bin | Should -BeExactly ([IO.Path]::GetFullPath((Join-Path $script:PovyProfileDir 'bin')))
        $script:Prof.Secrets['example_api_token'] | Should -BeExactly 'EXAMPLE_API_TOKEN'
        $script:Prof.WindowsShell | Should -Be @([IO.Path]::GetFullPath((Join-Path $script:PovyProfileDir 'shell/example.ps1')))
        $files = @($script:Prof.WindowsFiles)
        $files.Count | Should -Be 1
        $files[0].Path | Should -Be (Join-Path $script:PovyHome '.config/povy-example/example.conf')
        $files[0].Template | Should -BeTrue
        $files[0].Private | Should -BeTrue
    }

    It 'renders the files of the test profile with the secret of .env, and writes them for the owner alone' {
        Import-PovyTestProfile $fixture
        Add-Content -LiteralPath $script:PovyEnvFile -Value 'EXAMPLE_API_TOKEN=s3cr3t'
        $source = [System.IO.File]::ReadAllText((Join-Path $fixture 'files/example.conf'))
        $expected = $source.Replace('{{ secret(name="example_api_token") }}', 's3cr3t')
        $rendered = @(Get-PovyWindowsFileContent)
        $rendered.Count | Should -Be 1
        $rendered[0].Text | Should -BeExactly $expected

        Install-PovyWindowsFile $rendered
        $path = Join-Path $script:PovyHome '.config/povy-example/example.conf'
        [System.IO.File]::ReadAllText($path) | Should -BeExactly $expected
        Test-PovyOwnerOnly $path | Should -BeTrue
        $script:PovyWritten | Should -Be 1
        Install-PovyWindowsFile @(Get-PovyWindowsFileContent)
        $script:PovyWritten | Should -Be 1
        $script:PovyUnchanged | Should -Be 1
    }

    It 'reads the variable of each secret, given as a name or in a table' {
        Write-PovyTestFile (Join-Path $script:PovyProfileDir 'mise.toml') (@(
                '[bootstrap.secrets]'
                'plain = "POVY_TEST_PLAIN"'
                'table = { env = "POVY_TEST_TABLE", description = "a secret" }'
            ) -join "`n")
        Import-PovyProfile 'https://example.org/profile.git' ''
        $script:Prof.Secrets['plain'] | Should -BeExactly 'POVY_TEST_PLAIN'
        $script:Prof.Secrets['table'] | Should -BeExactly 'POVY_TEST_TABLE'
    }

    It 'refuses the secret <Value>, which names no environment variable' -ForEach @(
        @{ Value = '"bad-name"' }
        @{ Value = '{ env = "1st" }' }
        @{ Value = '{ description = "no env" }' }
        @{ Value = '3' }
    ) {
        Write-PovyTestFile (Join-Path $script:PovyProfileDir 'mise.toml') "[bootstrap.secrets]`nx = $Value"
        $err = Get-PovyError { Import-PovyProfile 'https://example.org/profile.git' '' }
        $err.Message | Should -BeLike '*mise.toml: bootstrap.secrets.x needs an environment variable'
    }

    It 'renders the vars of team.toml and mise.toml, those of mise.toml first, as mise does' {
        Write-PovyTestFile (Join-Path $script:PovyProfileDir 'team.toml') "[vars]`nname = `"team`"`nregion = `"eu`""
        Write-PovyTestFile (Join-Path $script:PovyProfileDir 'mise.toml') (@(
                '[vars]'
                'name = "project"'
                '[bootstrap.files."~/.x"]'
                'os = "unix"'
                'content = "{{ vars.name }} {{ vars.region }}"'
                'template = true'
                '[_.povy.windows]'
                'files = ["~/.x"]'
            ) -join "`n")
        Import-PovyProfile 'https://example.org/profile.git' ''
        @(Get-PovyWindowsFileContent)[0].Text | Should -BeExactly 'project eu'
    }

    It 'stops before rendering anything when a secret is empty' {
        Import-PovyTestProfile $fixture
        $err = Get-PovyError { Get-PovyWindowsFileContent }
        $err.Message | Should -BeExactly "~/.config/povy-example/example.conf: the secret example_api_token is empty; fill EXAMPLE_API_TOKEN in $($script:PovyEnvFile)"
    }

    It 'renders the Windows files of the sample profile' {
        Import-PovyTestProfile $sample
        Add-Content -LiteralPath $script:PovyEnvFile -Value 'SAMPLE_API_TOKEN=sample'
        $rendered = @(Get-PovyWindowsFileContent)
        $rendered.Count | Should -Be 2
        $rendered[0].Path | Should -Be (Join-Path $script:PovyHome '.config/povy-sample/sample.conf')
        $rendered[0].Text -split '\r?\n' | Should -Contain 'token = sample'
        $rendered[0].Private | Should -BeTrue
        $rendered[1].Path | Should -Be (Join-Path $script:PovyHome '.config/starship.toml')
        $rendered[1].Text | Should -BeExactly ([System.IO.File]::ReadAllText((Join-Path $sample 'files/starship.toml')))
        $rendered[1].Private | Should -BeFalse
        $script:Prof.WindowsShell | Should -Be @([IO.Path]::GetFullPath((Join-Path $script:PovyProfileDir 'shell/aliases.ps1')))
    }

    It 'renders a var that is a number or a boolean, as mise does' {
        Write-PovyTestFile (Join-Path $script:PovyProfileDir 'team.toml') "[vars]`nport = 8080`nsecure = true"
        Write-PovyTestFile (Join-Path $script:PovyProfileDir 'mise.toml') (@(
                '[bootstrap.files."~/.x"]'
                'os = "unix"'
                'content = "port = {{ vars.port }}, secure = {{ vars.secure }}"'
                'template = true'
                '[_.povy.windows]'
                'files = ["~/.x"]'
            ) -join "`n")
        Import-PovyProfile 'https://example.org/profile.git' ''
        @(Get-PovyWindowsFileContent)[0].Text | Should -BeExactly 'port = 8080, secure = true'
    }

    It 'writes a source that is not a template byte for byte' {
        $bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes("with a mark`r`nline`n"))
        [System.IO.File]::WriteAllBytes((Join-Path $script:PovyProfileRoot 'files/mark'), $bytes)
        $script:Prof.WindowsFiles = @(ConvertTo-PovyWindowsFile @{ '~/.mark' = @{ source = './files/mark' } } '~/.mark' $label)
        Install-PovyWindowsFile @(Get-PovyWindowsFileContent)
        [System.IO.File]::ReadAllBytes((Join-Path $script:PovyHome '.mark')) | Should -Be $bytes
    }
}

Describe 'the mise config of povy' {
    BeforeEach {
        $sandbox = Initialize-PovyTestRun
        $header = '# Generated by povy apply. Changes here are overwritten.'
        $yq = @('# povy reads its own configuration with yq.', '[tools]', '"yq" = "4"', '')
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'includes the team.toml of the profile, with forward slashes, and declares yq' {
        $script:Prof.Team = 'C:\Users\Ada\povy\profile\team.toml'
        $expected = @($header, "# The profile's team.toml, in every directory.", 'include = ["C:/Users/Ada/povy/profile/team.toml"]') + $yq
        Get-PovyMiseConfText | Should -BeExactly ($expected -join "`n")
    }

    It 'includes nothing without a team.toml' {
        Get-PovyMiseConfText | Should -BeExactly ((@($header) + $yq) -join "`n")
    }

    It 'quotes the path, so that it reads back as it is' {
        Install-PovyYq
        $script:Prof.Team = '/srv/a "quoted" dir/team.toml'
        $file = Join-Path $sandbox.Root 'povy.toml'
        [System.IO.File]::WriteAllText($file, (Get-PovyMiseConfText))
        $data = Read-PovyToml $file
        @($data['include']) | Should -BeExactly @('/srv/a "quoted" dir/team.toml')
        $data['tools']['yq'] | Should -BeExactly '4'
    }
}

Describe 'profile paths' {
    It 'accepts <Path>: <Valid>' -ForEach @(
        @{ Path = 'files/a.conf'; Valid = $true }
        @{ Path = '.config/x'; Valid = $true }
        @{ Path = '../outside'; Valid = $false }
        @{ Path = 'a/../b'; Valid = $false }
        @{ Path = '/etc/passwd'; Valid = $false }
        @{ Path = '~/x'; Valid = $false }
        @{ Path = 'C:/Windows'; Valid = $false }
        @{ Path = 'files\a'; Valid = $false }
        @{ Path = 'dir/'; Valid = $false }
    ) {
        Test-PovyRelativePath $Path | Should -Be $Valid
    }

    It 'turns identity directories into gitdir patterns' {
        ConvertTo-PovyIdentityDir '~/oss' | Should -BeExactly '~/oss/'
        ConvertTo-PovyIdentityDir 'C:\work\clients' | Should -BeExactly 'C:/work/clients/'
        ConvertTo-PovyIdentityDir 'relative/dir' | Should -BeNullOrEmpty
    }
}
