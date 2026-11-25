# Contexts in the PowerShell engine, as tests/contexts.bats checks them in the bash
# one: a Git identity, a profile, or both, below a directory, with mise for real in
# a sandbox.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester shares the variables of BeforeAll and BeforeEach with the It blocks')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'Helper.ps1')

    # A config.toml with the default identity, no default profile, and the given
    # [contexts.<id>] tables.
    function Write-PovyContextConfig([string]$File, [string[]]$Context) {
        Write-PovyTestConfig $File '' ("`n" + ($Context -join "`n`n"))
    }

    function Get-PovyContextTable([string]$Id, [string]$Dir, [hashtable]$Field = @{}) {
        $lines = @("[contexts.$Id]", "dir = `"$Dir`"")
        foreach ($key in $Field.Keys | Sort-Object) { $lines += "$key = `"$($Field[$key].Replace('\', '/'))`"" }
        return $lines -join "`n"
    }

    # The environment that mise gives a tool started in a directory, through a shim.
    function Get-PovyMiseEnv([string]$Dir) {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        $json = & mise -C $Dir env --json 2>$null
        if ($LASTEXITCODE -ne 0) { throw "mise env failed in $Dir" }
        return (($json -join "`n") | ConvertFrom-Json -AsHashtable)
    }

    function Invoke-PovyContextApply($Sandbox, [string]$Config) {
        New-Item -ItemType Directory -Force -Path $Sandbox.Launcher | Out-Null
        $init = Invoke-PovyCli init --config $Config
        if ($init.Code -ne 0) { throw "povy init failed: $($init.Output)" }
        return Invoke-PovyCli apply
    }
}

Describe 'contexts below directories' {
    BeforeAll {
        $sandbox = New-PovySandbox
        $orgRepo = Join-Path $sandbox.Root 'org'
        $productRepo = Join-Path $sandbox.Root 'product'
        New-PovyCustomProfile $orgRepo -Team "[env]`nORG = `"org`"`nCTX = `"org`""
        New-PovyCustomProfile $productRepo -Team "[env]`nCTX = `"product`""
        $config = Join-Path $sandbox.Root 'config.toml'
        Write-PovyContextConfig $config @(
            (Get-PovyContextTable 'org' '~/work/org/' @{ email = 'org@example.org'; profile = $orgRepo }),
            (Get-PovyContextTable 'product' '~/work/org/product/' @{ email = 'product@example.org'; name = 'Prod'; profile = $productRepo }),
            (Get-PovyContextTable 'solo' '~/solo/' @{ email = 'solo@example.org' }),
            "[[identities]]`ndir = `"~/work/`"`nemail = `"work@example.org`"",
            # The product context, of the same directory, wins over it.
            "[[identities]]`ndir = `"~/work/org/product/`"`nemail = `"shadowed@example.org`""
        )
        $apply = Invoke-PovyContextApply $sandbox $config
        if ($apply.Code -ne 0) { throw "povy apply failed: $($apply.Output)" }
    }
    AfterAll {
        Remove-PovySandbox $sandbox
    }

    It 'writes the mise config of each context, which includes its team.toml' {
        $conf = Join-Path $sandbox.Home 'work/org/product/.config/mise/conf.d/povy.toml'
        $team = [IO.Path]::GetFullPath((Join-Path $sandbox.State 'contexts/product/profile/team.toml')).Replace('\', '/')
        Get-Content -LiteralPath $conf | Should -Contain "include = [`"$team`"]"
    }

    It 'has mise apply the deepest context over its parent, and no context elsewhere' {
        $product = Get-PovyMiseEnv (Join-Path $sandbox.Home 'work/org/product/app')
        $product['CTX'] | Should -BeExactly 'product'
        $product['ORG'] | Should -BeExactly 'org'
        (Get-PovyMiseEnv (Join-Path $sandbox.Home 'work/org/other'))['CTX'] | Should -BeExactly 'org'
        (Get-PovyMiseEnv (Join-Path $sandbox.Home 'elsewhere')).ContainsKey('CTX') | Should -BeFalse
    }

    It 'sets the Git identity of each context and identity, the deepest winning' {
        foreach ($repo in 'work/org/product/r', 'work/org/r', 'work/r', 'solo/r', 'r') {
            $path = Join-Path $sandbox.Home $repo
            New-Item -ItemType Directory -Force -Path $path | Out-Null
            git -C $path init --quiet
        }
        git -C (Join-Path $sandbox.Home 'work/org/product/r') config user.email | Should -BeExactly 'product@example.org'
        git -C (Join-Path $sandbox.Home 'work/org/product/r') config user.name | Should -BeExactly 'Prod'
        git -C (Join-Path $sandbox.Home 'work/org/r') config user.email | Should -BeExactly 'org@example.org'
        git -C (Join-Path $sandbox.Home 'work/r') config user.email | Should -BeExactly 'work@example.org'
        git -C (Join-Path $sandbox.Home 'solo/r') config user.email | Should -BeExactly 'solo@example.org'
        git -C (Join-Path $sandbox.Home 'r') config user.email | Should -BeExactly 'test@example.org'
    }

    It 'leaves no clone and no mise config for a context that only sets an identity' {
        Test-Path -LiteralPath (Join-Path $sandbox.Home 'solo/.config') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $sandbox.State 'contexts/solo') | Should -BeFalse
    }

    It 'lists the contexts and identities of a directory with status, the deepest first' {
        $dir = Join-Path $sandbox.Home 'work/org/product/app'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $status = Invoke-PovyCli status $dir
        $status.Code | Should -Be 0 -Because $status.Output
        $lines = @($status.Output -split "`n")
        $lines[0] | Should -Match 'app, the first that sets something wins:$'
        $lines[1] | Should -Match '^\s+product\s+~/work/org/product/: profile product, Git identity product@example\.org$'
        $lines[2] | Should -Match '^\s+\(identity\)\s+~/work/org/product/: Git identity shadowed@example\.org$'
        $lines[3] | Should -Match '^\s+org\s+~/work/org/: profile org, Git identity org@example\.org$'
        $lines[4] | Should -Match '^\s+\(identity\)\s+~/work/: Git identity work@example\.org$'
        $lines[5] | Should -Match '^\s+\(default\)\s+every directory: Git identity test@example\.org$'
    }

    It 'keeps POVY_CONTEXT on the context of the current location in a new session' {
        foreach ($dir in 'work/org/product/app', 'work/organic', 'solo') {
            New-Item -ItemType Directory -Force -Path (Join-Path $sandbox.Home $dir) | Out-Null
        }
        $command = @(
            ". '$($sandbox.PsProfile)'",
            '"home=$env:POVY_CONTEXT"',
            "Set-Location '$(Join-Path $sandbox.Home 'work/org/product/app')'",
            '"product=$env:POVY_CONTEXT"',
            "Set-Location '$(Join-Path $sandbox.Home 'work/organic')'",
            '"organic=$env:POVY_CONTEXT"',
            "Set-Location '$(Join-Path $sandbox.Home 'solo')'",
            '"solo=$env:POVY_CONTEXT"',
            'Set-Location Env:',
            '"env=$env:POVY_CONTEXT"'
        ) -join '; '
        # A value left by the session that started this one goes.
        $env:POVY_CONTEXT = 'stale'
        try {
            $session = @(& $script:Pwsh -NoProfile -WorkingDirectory $sandbox.Home -Command $command 2>&1 | ForEach-Object { "$_" })
        } finally {
            Remove-Item Env:POVY_CONTEXT -ErrorAction Ignore
        }
        $session | Should -Be @('home=', 'product=product', 'organic=', 'solo=solo', 'env=')
    }

    It 'passes doctor, which checks every context' {
        $doctor = Invoke-PovyCli doctor
        $doctor.Code | Should -Be 0 -Because $doctor.Output
        $doctor.Output | Should -Match 'context product: mise reads its config in'
    }

    It 'writes nothing on a second apply' {
        $again = Invoke-PovyCli apply
        $again.Code | Should -Be 0 -Because $again.Output
        $again.Output | Should -Match 'Applied: 0 written'
    }
}

Describe 'a context that needs a secret' {
    BeforeAll {
        $sandbox = New-PovySandbox
        $repo = Join-Path $sandbox.Root 'profile'
        New-PovyProfileRepo $repo
        $config = Join-Path $sandbox.Root 'config.toml'
        Write-PovyContextConfig $config @((Get-PovyContextTable 'team' '~/work/team/' @{ profile = $repo }))
        $first = Invoke-PovyContextApply $sandbox $config
        $contextEnv = Join-Path $sandbox.Home '.config/povy/team.env'
        $example = Join-Path $sandbox.Home '.config/povy-example/example.conf'
    }
    AfterAll {
        Remove-PovySandbox $sandbox
    }

    It 'stops apply and adds the secret to the .env of the context, for the owner alone' {
        $first.Code | Should -Not -Be 0
        $first.Output | Should -Match 'EXAMPLE_API_TOKEN'
        $first.Output | Should -Match 'team\.env'
        Get-Content -LiteralPath $contextEnv | Should -Contain 'EXAMPLE_API_TOKEN='
        Test-PovyOwnerOnly $contextEnv | Should -BeTrue
        Test-Path -LiteralPath $example | Should -BeFalse
    }

    It 'reads the secret in the shared .env, then in its own' {
        Add-Content -LiteralPath $sandbox.EnvFile -Value 'EXAMPLE_API_TOKEN=shared'
        $apply = Invoke-PovyCli apply
        $apply.Code | Should -Be 0 -Because $apply.Output
        Get-Content -LiteralPath $example | Should -Contain 'token = shared'
        [System.IO.File]::WriteAllText($contextEnv, "EXAMPLE_API_TOKEN=own`n")
        $apply = Invoke-PovyCli apply
        $apply.Code | Should -Be 0 -Because $apply.Output
        Get-Content -LiteralPath $example | Should -Contain 'token = own'
    }
}

Describe 'two contexts that write the same file' {
    BeforeAll {
        $sandbox = New-PovySandbox
        $a = Join-Path $sandbox.Root 'a'
        $b = Join-Path $sandbox.Root 'b'
        New-PovyProfileRepo $a
        New-PovyProfileRepo $b
        $config = Join-Path $sandbox.Root 'config.toml'
        Write-PovyContextConfig $config @(
            (Get-PovyContextTable 'a' '~/work/a/' @{ profile = $a }),
            (Get-PovyContextTable 'b' '~/work/b/' @{ profile = $b })
        )
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sandbox.EnvFile) | Out-Null
        Add-Content -LiteralPath $sandbox.EnvFile -Value 'EXAMPLE_API_TOKEN=s3cr3t'
        $apply = Invoke-PovyContextApply $sandbox $config
    }
    AfterAll {
        Remove-PovySandbox $sandbox
    }

    It 'stops apply before anything changes' {
        $apply.Code | Should -Not -Be 0
        $apply.Output | Should -Match ([regex]::Escape('example.conf: written by context a and by context b'))
        Test-Path -LiteralPath (Join-Path $sandbox.Home 'work/a/.config/mise/conf.d/povy.toml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $sandbox.Home '.config/povy-example/example.conf') | Should -BeFalse
    }
}

Describe 'a context that goes' {
    BeforeAll {
        $sandbox = New-PovySandbox
        $repo = Join-Path $sandbox.Root 'gone'
        New-PovyCustomProfile $repo -Team "[env]`nCTX = `"gone`""
        $config = Join-Path $sandbox.Root 'config.toml'
        Write-PovyContextConfig $config @((Get-PovyContextTable 'gone' '~/work/gone/' @{ profile = $repo }))
        $first = Invoke-PovyContextApply $sandbox $config
        $contextEnv = Join-Path $sandbox.Home '.config/povy/gone.env'
        [System.IO.File]::WriteAllText($contextEnv, "KEEP=1`n")
        Write-PovyTestConfig $config
        $second = Invoke-PovyContextApply $sandbox $config
    }
    AfterAll {
        Remove-PovySandbox $sandbox
    }

    It 'takes its mise config and its clone along, and keeps its .env' {
        $first.Code | Should -Be 0 -Because $first.Output
        $second.Code | Should -Be 0 -Because $second.Output
        Test-Path -LiteralPath (Join-Path $sandbox.Home 'work/gone/.config') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $sandbox.State 'contexts/gone') | Should -BeFalse
        Get-Content -LiteralPath $contextEnv | Should -Contain 'KEEP=1'
    }
}

Describe 'the env of a context' {
    BeforeAll {
        $sandbox = New-PovySandbox
        $repo = Join-Path $sandbox.Root 'a'
        New-PovyCustomProfile $repo -Team "[env]`nCTX = `"team`"`nONLY_TEAM = `"team`""
        $config = Join-Path $sandbox.Root 'config.toml'
        Write-PovyContextConfig $config @(
            ((Get-PovyContextTable 'a' '~/work/a/' @{ profile = $repo }) + "`nenv = { CTX = `"machine`", CONF = `"~/.conf-a`" }"),
            # Only env: no Git identity and no profile.
            "[contexts.b]`ndir = `"~/work/b/`"`n`n[contexts.b.env]`nCONF = `"~/.conf-b`""
        )
        $apply = Invoke-PovyContextApply $sandbox $config
        if ($apply.Code -ne 0) { throw "povy apply failed: $($apply.Output)" }
    }
    AfterAll {
        Remove-PovySandbox $sandbox
    }

    It 'applies below the directory, over the team.toml, with ~/ expanded' {
        $a = Get-PovyMiseEnv (Join-Path $sandbox.Home 'work/a/app')
        $a['CTX'] | Should -BeExactly 'machine'
        $a['ONLY_TEAM'] | Should -BeExactly 'team'
        $a['CONF'] | Should -BeExactly ([IO.Path]::GetFullPath((Join-Path $sandbox.Home '.conf-a')))
        (Get-PovyMiseEnv (Join-Path $sandbox.Home 'work/b/app'))['CONF'] | Should -BeExactly ([IO.Path]::GetFullPath((Join-Path $sandbox.Home '.conf-b')))
        (Get-PovyMiseEnv (Join-Path $sandbox.Home 'work')).ContainsKey('CONF') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $sandbox.State 'contexts/b') | Should -BeFalse
    }

    It 'shows the names of the variables with status' {
        $status = Invoke-PovyCli status (Join-Path $sandbox.Home 'work/b')
        $status.Code | Should -Be 0 -Because $status.Output
        @($status.Output -split "`n")[1] | Should -Match '^\s+b\s+~/work/b/: env CONF$'
    }

    It 'passes doctor, and writes nothing on a second apply' {
        $doctor = Invoke-PovyCli doctor
        $doctor.Code | Should -Be 0 -Because $doctor.Output
        $doctor.Output | Should -Match 'context b: mise config: .* with env CONF'
        $again = Invoke-PovyCli apply
        $again.Code | Should -Be 0 -Because $again.Output
        $again.Output | Should -Match 'Applied: 0 written'
    }
}

Describe 'a default profile moved to a context' {
    BeforeAll {
        $sandbox = New-PovySandbox
        $repo = Join-Path $sandbox.Root 'moved'
        New-PovyCustomProfile $repo -Team "[env]`nCTX = `"moved`""
        $config = Join-Path $sandbox.Root 'config.toml'
        Write-PovyTestConfig $config $repo
        $first = Invoke-PovyContextApply $sandbox $config
        $cloned = Test-Path -LiteralPath $sandbox.Clone
        Write-PovyContextConfig $config @((Get-PovyContextTable 'moved' '~/work/moved/' @{ profile = $repo }))
        $second = Invoke-PovyContextApply $sandbox $config
    }
    AfterAll {
        Remove-PovySandbox $sandbox
    }

    It 'leaves no clone of the former default profile' {
        $first.Code | Should -Be 0 -Because $first.Output
        $cloned | Should -BeTrue
        $second.Code | Should -Be 0 -Because $second.Output
        $second.Output | Should -Match 'the clone of the former default profile'
        Test-Path -LiteralPath $sandbox.Clone | Should -BeFalse
        (Get-PovyMiseEnv (Join-Path $sandbox.Home 'work/moved/app'))['CTX'] | Should -BeExactly 'moved'
        (Get-PovyMiseEnv (Join-Path $sandbox.Home 'elsewhere')).ContainsKey('CTX') | Should -BeFalse
    }
}

Describe 'contexts that config.toml refuses' {
    BeforeAll {
        $sandbox = New-PovySandbox
        $config = Join-Path $sandbox.Root 'config.toml'
    }
    AfterAll {
        Remove-PovySandbox $sandbox
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'an id in capitals'; Body = "[contexts.Bad]`ndir = `"~/w/`"`nemail = `"a@example.org`"" }
        @{ Name = 'no dir'; Body = "[contexts.a]`nemail = `"a@example.org`"" }
        @{ Name = 'a relative dir'; Body = "[contexts.a]`ndir = `"w/`"`nemail = `"a@example.org`"" }
        @{ Name = 'the home directory'; Body = "[contexts.a]`ndir = `"~/`"`nemail = `"a@example.org`"" }
        @{ Name = 'neither email nor profile'; Body = "[contexts.a]`ndir = `"~/w/`"" }
        @{ Name = 'a name without an email'; Body = "[contexts.a]`ndir = `"~/w/`"`nname = `"A`"" }
        @{ Name = 'a ref without a profile'; Body = "[contexts.a]`ndir = `"~/w/`"`nemail = `"a@example.org`"`nprofile_ref = `"main`"" }
        @{ Name = 'an unknown key'; Body = "[contexts.a]`ndir = `"~/w/`"`nemail = `"a@example.org`"`ncolour = `"red`"" }
        @{ Name = 'two contexts on one directory'; Body = "[contexts.a]`ndir = `"~/w/`"`nemail = `"a@example.org`"`n[contexts.b]`ndir = `"~/w`"`nemail = `"b@example.org`"" }
        @{ Name = 'contexts that are not tables'; Body = 'contexts = 1' }
        @{ Name = 'an env that is not a table'; Body = "[contexts.a]`ndir = `"~/w/`"`nenv = `"X=1`"" }
        @{ Name = 'an invalid variable name'; Body = "[contexts.a]`ndir = `"~/w/`"`nenv = { `"BAD-NAME`" = `"x`" }" }
        @{ Name = 'PATH in env'; Body = "[contexts.a]`ndir = `"~/w/`"`nenv = { PATH = `"/x`" }" }
        @{ Name = 'a variable that is not a string'; Body = "[contexts.a]`ndir = `"~/w/`"`nenv = { N = 1 }" }
        @{ Name = 'an empty env alone'; Body = "[contexts.a]`ndir = `"~/w/`"`nenv = {}" }
    ) {
        Write-PovyContextConfig $config @($Body)
        $init = Invoke-PovyCli init --config $config
        $init.Code | Should -Not -Be 0
        $init.Output | Should -Match 'context'
    }
}
