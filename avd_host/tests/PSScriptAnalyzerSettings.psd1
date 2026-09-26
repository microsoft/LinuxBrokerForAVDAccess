# PSScriptAnalyzer settings for the AVD session host script and the script that updates it,
# used by the avd-scripts job in .github/workflows/front-end-tests.yml.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The flagged New-* functions only build objects in memory; there is nothing for -WhatIf
        # to skip.
        'PSUseShouldProcessForStateChangingFunctions',
        # Update-AvdHostBrokerScript.ps1 reports its progress to the operator who runs it, as the
        # other deployment scripts do.
        'PSAvoidUsingWriteHost'
    )
}
