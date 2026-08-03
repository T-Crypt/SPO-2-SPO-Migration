@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # The module intentionally uses Write-Host for the operator-facing CLI
        # and live dashboard; structured logging goes through Write-SPOLog.
        'PSAvoidUsingWriteHost',
        # ShouldProcess is applied at the public entry points; private helpers
        # deliberately do not re-prompt.
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Rules = @{
        PSPlaceOpenBrace           = @{ Enable = $true; OnSameLine = $true }
        PSUseConsistentIndentation = @{ Enable = $true; Kind = 'space'; IndentationSize = 4 }
        PSAvoidUsingPlainTextForPassword = @{ Enable = $true }
        PSAvoidUsingConvertToSecureStringWithPlainText = @{ Enable = $true }
    }
}
