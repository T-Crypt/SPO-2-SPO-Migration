@{
    RootModule        = 'SPOMigrate.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b3f6a1e2-9c4d-4e7a-8f21-6d0c5a7e4b90'
    Author            = 'Xceptional'
    CompanyName       = 'Xceptional'
    Copyright         = '(c) Xceptional. All rights reserved.'
    Description       = 'Resumable, verified, throttle-aware SharePoint-to-SharePoint migration tool.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Start-SPOMigration'
        'Show-SPOMigrationWizard'
        'Test-SPOMigrationEnvironment'
        'Get-SPOMigrationStatus'
        'New-SPOMigrationReport'
        'Import-SPOMigrationConfig'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('SharePoint', 'Migration', 'PnP', 'M365', 'Xceptional')
            ProjectUri   = 'https://github.com/xceptional/SPO-2-SPO-Migration'
            LicenseUri   = 'https://opensource.org/licenses/MIT'
            ReleaseNotes = 'See CHANGELOG.md'
        }
    }
}
