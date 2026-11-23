# bootstrap.ps1, which installs povy on Windows.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares the variables of BeforeAll and BeforeEach with the It blocks')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helper.ps1')
    $bootstrap = Join-Path $script:PovyRoot 'bootstrap.ps1'
}

Describe 'bootstrap.ps1' {
    BeforeEach {
        $sandbox = New-PovySandbox
    }
    AfterEach {
        Remove-PovySandbox $sandbox
    }

    It 'points to the other bootstrap outside Windows' -Skip:$IsWindows {
        $output = & $script:Pwsh -NoProfile -File $bootstrap 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($output -join "`n") | Should -Match 'this bootstrap is for Windows'
    }

    It 'clones the engine, installs the povy command and puts it on the user PATH' -Skip:(-not $IsWindows) {
        # A repository with a main branch at the commit under test.
        $source = Join-Path $sandbox.Root 'source'
        git init --quiet $source
        git -C $source fetch --quiet $script:PovyRoot "$(git -C $script:PovyRoot rev-parse HEAD):refs/heads/main"
        $env:POVY_REPO = $source
        $env:POVY_BRANCH = 'main'
        $env:POVY_BOOTSTRAP_NO_INIT = '1'

        $output = & $script:Pwsh -NoProfile -File $bootstrap 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $launcher = Join-Path $sandbox.Local 'povy\bin\povy.cmd'
        Test-Path -LiteralPath $launcher | Should -BeTrue
        (Get-Content -Raw -LiteralPath $sandbox.UserPath).Split(';')[0] | Should -BeExactly '%LOCALAPPDATA%\povy\bin'
        (& $launcher version) | Should -Match '^povy '

        $again = & $script:Pwsh -NoProfile -File $bootstrap 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($again -join "`n")
        @((Get-Content -Raw -LiteralPath $sandbox.UserPath).Split(';') | Where-Object { $_ -like '*povy*' }).Count | Should -Be 1
    }
}
