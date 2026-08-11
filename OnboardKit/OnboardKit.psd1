@{
    RootModule        = 'OnboardKit.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '47c9eea3-d720-4bd3-a566-d7750fb3ad24'
    Author            = 'Cory "TrogdorTheMan" Francis'
    Copyright         = 'Copyright (C) 2026 Cory "TrogdorTheMan" Francis. Licensed under AGPL-3.0-or-later.'
    Description       = 'Shared helper functions for MSPOnboardKit: configuration loading, email alias generation, and temporary password generation.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Import-OnboardKitConfig'
        'ConvertTo-OnboardNameToken'
        'ConvertTo-OnboardAlias'
        'ConvertTo-OnboardSamAccountName'
        'Test-OnboardAliasInUse'
        'Get-UniqueOnboardAlias'
        'New-OnboardTempPassword'
        'Test-OnboardLicensingGroup'
        'Get-OnboardParentOU'
        'Test-OnboardProtectedOU'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('ActiveDirectory', 'Microsoft365', 'Onboarding', 'MSP', 'Automation')
            LicenseUri = 'https://www.gnu.org/licenses/agpl-3.0.html'
            ProjectUri = 'https://github.com/TrogdorTheMan/MSPOnboardKit'
        }
    }
}
