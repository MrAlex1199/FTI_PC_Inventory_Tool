@{
    # PSScriptAnalyzer Enterprise Rules Configuration for FTI PC Inventory Tool
    Severity = @('Error', 'Warning')
    
    IncludeRules = @(
        'PSAvoidDefaultValueSwitchParameter',
        'PSAvoidNullOrEmptyHelpMessageAttribute',
        'PSAvoidUsingEmptyCatchBlock',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingPositionalParameters',
        'PSAvoidUsingWMICmdlet',
        'PSUseApprovedVerbs',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSUseSingularNouns',
        'PSUseToExportFieldsInManifest'
    )
    
    ExcludeRules = @(
        # Exclude positional parameter warning for legacy WMI / internal formatting scripts if needed
        'PSAvoidUsingPositionalParameters'
    )
}

