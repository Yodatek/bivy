# The building blocks of the PowerShell engine, called directly in a sandbox.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares the variables of BeforeAll and BeforeEach with the It blocks')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helper.ps1')
    foreach ($lib in 'common', 'config', 'profile', 'system', 'git', 'commands') {
        . (Join-Path $script:PovyRoot "lib/ps/$lib.ps1")
    }
}

Describe 'marked blocks' {
    BeforeEach {
        $sandbox = New-PovySandbox
        Initialize-PovyPath
        Initialize-PovyDirectory
        $script:PovyBackupDir = $null
        $script:PovyBackedUp = 0
        $script:PovyCreated.Clear()
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
        $sandbox = New-PovySandbox
        Initialize-PovyPath
        Initialize-PovyDirectory
        $script:Prof = [ordered]@{ Secrets = @(); Tools = [ordered]@{}; Prompt = ''; Packages = @(); Bin = 'bin'; Shell = @(); Files = @() }
        $script:PovyProfileRoot = $script:PovyProfileDir
        New-Item -ItemType Directory -Force -Path $script:PovyLauncherDir | Out-Null
        $other = if ($IsWindows) { 'C:\Other\bin' } else { '/opt/other/bin' }
        $stale = Join-Path $script:PovyDataDir 'state/profile/old-bin'
        [System.IO.File]::WriteAllText($sandbox.UserPath, "%POVY_TEST_UNSET%\tools;$other;$stale;$($script:PovyShimsDir)")
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'puts the shims, the profile commands and povy first, and keeps other entries as written' {
        Update-PovyUserPath
        $entries = (Get-Content -Raw -LiteralPath $sandbox.UserPath).Trim() -split ';'
        $expanded = @($entries | ForEach-Object { [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($_)) })
        $expanded[0] | Should -Be ([IO.Path]::GetFullPath($script:PovyShimsDir))
        $expanded[1] | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:PovyProfileDir 'bin')))
        $expanded[2] | Should -Be ([IO.Path]::GetFullPath($script:PovyLauncherDir))
        $entries[3] | Should -BeExactly '%POVY_TEST_UNSET%\tools'
        $entries[4] | Should -Be $other
        # On Windows, mise itself follows when the system PATH lacks it: its shims need it.
        $miseDir = Get-PovyMissingMiseDir
        if ($miseDir) {
            [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($entries[5])) | Should -Be ([IO.Path]::GetFullPath($miseDir))
        }
        $entries.Count | Should -Be (5 + [int][bool]$miseDir)
    }

    It 'changes nothing on a second run' {
        Update-PovyUserPath
        $first = Get-Content -Raw -LiteralPath $sandbox.UserPath
        $before = $script:PovyWritten
        Update-PovyUserPath
        Get-Content -Raw -LiteralPath $sandbox.UserPath | Should -BeExactly $first
        $script:PovyWritten | Should -Be $before
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

Describe 'secrets and templates' {
    BeforeEach {
        $sandbox = New-PovySandbox
        Initialize-PovyPath
        Initialize-PovyDirectory
        Initialize-PovyEnvFile
        $script:Cfg = [ordered]@{ Name = 'Ada Lovelace'; Email = 'ada@example.org' }
        $script:Prof = [ordered]@{ Secrets = @('TOKEN'); Tools = [ordered]@{}; Prompt = ''; Packages = @(); Bin = ''; Shell = @(); Files = @() }
        $template = Join-Path $sandbox.Root 'template'
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

    It 'replaces the placeholders, case-sensitive, and passes other syntaxes through' {
        Add-Content -LiteralPath $script:PovyEnvFile -Value 'TOKEN=t0k3n'
        [System.IO.File]::WriteAllText($template, '{{name}} <{{email}}> {{home}} {{TOKEN}} ${keep} {{ spaced }}')
        ConvertFrom-PovyTemplate $template |
            Should -BeExactly "Ada Lovelace <ada@example.org> $($script:PovyHome) t0k3n `${keep} {{ spaced }}"
        [System.IO.File]::WriteAllText($template, '{{NAME}}')
        { ConvertFrom-PovyTemplate $template } | Should -Throw '*unknown placeholder {{NAME}}*'
    }

    It 'makes a file private to its owner' {
        $file = Join-Path $sandbox.Root 'secret'
        [System.IO.File]::WriteAllText($file, 'x')
        Set-PovyPrivate $file
        Test-PovyPrivate $file | Should -BeTrue
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
