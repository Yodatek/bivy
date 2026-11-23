# Lint rules of the PowerShell engine, for scripts/ps-tasks.ps1 lint.
@{
    Severity = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        # povy commands are explicit actions; they offer no -WhatIf.
        'PSUseShouldProcessForStateChangingFunctions',
        # Internal helpers take positional arguments: their names say what they read.
        'PSAvoidUsingPositionalParameters'
    )
}
