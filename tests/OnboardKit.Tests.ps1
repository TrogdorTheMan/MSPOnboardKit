<#
    MSPOnboardKit - unit tests
    Copyright (C) 2026 Cory "TrogdorTheMan" Francis
    Licensed under AGPL-3.0-or-later. See LICENSE.

    Requires Pester 5:
        Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck

    Run from the repository root:
        Invoke-Pester .\tests

    These tests need no Active Directory and no Microsoft 365 tenant. The one
    function that talks to AD (Test-OnboardAliasInUse) is mocked, which is
    exactly why it exists as a separate function.

    ENCODING: this file must stay UTF-8 WITH BOM. It contains accented names
    (Jose, Nunez, Astrom with their real diacritics) as test data, and Windows
    PowerShell 5.1 assumes ANSI for files with no BOM - which corrupts them
    and produces confusing failures that look like bugs in the code.
#>

BeforeAll {
    $script:ModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'OnboardKit\OnboardKit.psd1'
    Import-Module $script:ModulePath -Force
}

AfterAll {
    Remove-Module OnboardKit -Force -ErrorAction SilentlyContinue
}


Describe 'ConvertTo-OnboardNameToken' {

    It 'lowercases a plain name' {
        ConvertTo-OnboardNameToken -Value 'Smith' | Should -Be 'smith'
    }

    It 'strips an apostrophe' {
        ConvertTo-OnboardNameToken -Value "O'Brien" | Should -Be 'obrien'
    }

    It 'strips a hyphen' {
        ConvertTo-OnboardNameToken -Value 'Mary-Jane' | Should -Be 'maryjane'
    }

    It 'strips a space' {
        ConvertTo-OnboardNameToken -Value 'Van Der Berg' | Should -Be 'vanderberg'
    }

    It 'strips accents down to plain letters' {
        ConvertTo-OnboardNameToken -Value 'José' | Should -Be 'jose'
        ConvertTo-OnboardNameToken -Value 'Núñez' | Should -Be 'nunez'
        ConvertTo-OnboardNameToken -Value 'Åström' | Should -Be 'astrom'
    }

    It 'keeps digits' {
        ConvertTo-OnboardNameToken -Value 'Smith2' | Should -Be 'smith2'
    }

    It 'returns an empty string for whitespace' {
        ConvertTo-OnboardNameToken -Value '   ' | Should -Be ''
    }
}


Describe 'ConvertTo-OnboardAlias' {

    Context 'common naming conventions' {

        It 'builds first-initial + last name' {
            ConvertTo-OnboardAlias -FirstName 'John' -LastName 'Smith' -Template '{first:1}{last}' |
                Should -Be 'jsmith'
        }

        It 'builds first.last' {
            ConvertTo-OnboardAlias -FirstName 'John' -LastName 'Smith' -Template '{first}.{last}' |
                Should -Be 'john.smith'
        }

        It 'builds firstlast' {
            ConvertTo-OnboardAlias -FirstName 'John' -LastName 'Smith' -Template '{first}{last}' |
                Should -Be 'johnsmith'
        }

        It 'builds first + last-initial' {
            ConvertTo-OnboardAlias -FirstName 'John' -LastName 'Smith' -Template '{first}{last:1}' |
                Should -Be 'johns'
        }

        It 'supports an underscore separator' {
            ConvertTo-OnboardAlias -FirstName 'John' -LastName 'Smith' -Template '{first}_{last}' |
                Should -Be 'john_smith'
        }
    }

    Context 'awkward real-world names' {

        It 'handles an apostrophe' {
            ConvertTo-OnboardAlias -FirstName 'Sean' -LastName "O'Brien" -Template '{first:1}{last}' |
                Should -Be 'sobrien'
        }

        It 'handles a hyphenated first name' {
            ConvertTo-OnboardAlias -FirstName 'Mary-Jane' -LastName 'Watson' -Template '{first:1}{last}' |
                Should -Be 'mwatson'
        }

        It 'handles accents' {
            ConvertTo-OnboardAlias -FirstName 'José' -LastName 'Núñez' -Template '{first:1}{last}' |
                Should -Be 'jnunez'
        }
    }

    Context 'token lengths' {

        It 'truncates to the requested length' {
            ConvertTo-OnboardAlias -FirstName 'Alexander' -LastName 'Smith' -Template '{first:4}{last}' |
                Should -Be 'alexsmith'
        }

        It 'takes the whole name when the requested length is longer than the name' {
            ConvertTo-OnboardAlias -FirstName 'Al' -LastName 'Li' -Template '{first:5}{last:5}' |
                Should -Be 'alli'
        }

        It 'accepts a length of exactly the name length' {
            ConvertTo-OnboardAlias -FirstName 'John' -LastName 'Smith' -Template '{first:4}{last:5}' |
                Should -Be 'johnsmith'
        }
    }

    Context 'bad templates fail loudly' {

        It 'rejects an unknown token' {
            { ConvertTo-OnboardAlias -FirstName 'John' -LastName 'Smith' -Template '{firstname}{last}' } |
                Should -Throw -ExpectedMessage '*Unknown token*'
        }

        It 'rejects a zero length' {
            { ConvertTo-OnboardAlias -FirstName 'John' -LastName 'Smith' -Template '{first:0}{last}' } |
                Should -Throw -ExpectedMessage '*must be 1 or greater*'
        }

        It 'rejects an unmatched brace' {
            { ConvertTo-OnboardAlias -FirstName 'John' -LastName 'Smith' -Template '{first{last}' } |
                Should -Throw -ExpectedMessage '*unmatched brace*'
        }

        It 'rejects a template with no tokens at all' {
            { ConvertTo-OnboardAlias -FirstName 'John' -LastName 'Smith' -Template 'hello world' } |
                Should -Throw
        }

        It 'rejects names with no usable characters' {
            { ConvertTo-OnboardAlias -FirstName '...' -LastName '???' -Template '{first:1}{last}' } |
                Should -Throw -ExpectedMessage '*no alias can be built*'
        }

        It 'rejects an alias longer than 64 characters' {
            $long = 'a' * 40
            { ConvertTo-OnboardAlias -FirstName $long -LastName $long -Template '{first}{last}' } |
                Should -Throw -ExpectedMessage '*exceeds the 64 character limit*'
        }
    }
}


Describe 'ConvertTo-OnboardSamAccountName' {

    It 'leaves a short alias alone' {
        ConvertTo-OnboardSamAccountName -Alias 'jsmith' | Should -Be 'jsmith'
    }

    It 'leaves an alias of exactly 20 characters alone' {
        $alias = 'a' * 20
        ConvertTo-OnboardSamAccountName -Alias $alias | Should -Be $alias
    }

    It 'truncates an alias longer than 20 characters' {
        ConvertTo-OnboardSamAccountName -Alias 'bartholomewfitzgeraldsmith' |
            Should -Be 'bartholomewfitzgeral'
    }

    It 'never returns more than 20 characters' {
        (ConvertTo-OnboardSamAccountName -Alias ('x' * 100)).Length | Should -Be 20
    }
}


Describe 'Get-UniqueOnboardAlias' {

    It 'returns the base alias when nothing is using it' {
        Mock -ModuleName OnboardKit Test-OnboardAliasInUse { return $false }

        Get-UniqueOnboardAlias -BaseAlias 'jsmith' -Domain 'example.com' |
            Should -Be 'jsmith'
    }

    It 'appends 2 when the base alias is taken' {
        Mock -ModuleName OnboardKit Test-OnboardAliasInUse {
            param($Alias)
            return ($Alias -eq 'jsmith')
        }

        Get-UniqueOnboardAlias -BaseAlias 'jsmith' -Domain 'example.com' |
            Should -Be 'jsmith2'
    }

    It 'keeps counting up while aliases are taken' {
        Mock -ModuleName OnboardKit Test-OnboardAliasInUse {
            param($Alias)
            return ($Alias -in @('jsmith', 'jsmith2', 'jsmith3'))
        }

        Get-UniqueOnboardAlias -BaseAlias 'jsmith' -Domain 'example.com' |
            Should -Be 'jsmith4'
    }

    It 'never skips straight to a number when the base is free' {
        Mock -ModuleName OnboardKit Test-OnboardAliasInUse { return $false }

        Get-UniqueOnboardAlias -BaseAlias 'newperson' -Domain 'example.com' |
            Should -Not -Match '\d$'
    }

    It 'throws once it runs out of attempts' {
        Mock -ModuleName OnboardKit Test-OnboardAliasInUse { return $true }

        { Get-UniqueOnboardAlias -BaseAlias 'jsmith' -Domain 'example.com' -MaxAttempts 5 } |
            Should -Throw -ExpectedMessage '*after 5 attempts*'
    }

    It 'stops checking as soon as it finds a free alias' {
        Mock -ModuleName OnboardKit Test-OnboardAliasInUse {
            param($Alias)
            return ($Alias -eq 'jsmith')
        }

        $null = Get-UniqueOnboardAlias -BaseAlias 'jsmith' -Domain 'example.com'

        Should -Invoke -ModuleName OnboardKit Test-OnboardAliasInUse -Times 2 -Exactly
    }
}


Describe 'New-OnboardTempPassword' {

    It 'returns the requested length' {
        (New-OnboardTempPassword -Length 16).Length | Should -Be 16
        (New-OnboardTempPassword -Length 24).Length | Should -Be 24
    }

    It 'defaults to 16 characters' {
        (New-OnboardTempPassword).Length | Should -Be 16
    }

    It 'always contains an uppercase letter, a lowercase letter, a digit and a symbol' {
        # -CMatch, not -Match: PowerShell's -Match is case-insensitive, so
        # '[A-Z]' would happily match a lowercase-only password and this test
        # would pass without proving anything.
        # Repeated, because a complexity bug can easily pass a single sample.
        1..50 | ForEach-Object {
            $password = New-OnboardTempPassword -Length 12
            $password | Should -CMatch '[A-Z]'
            $password | Should -CMatch '[a-z]'
            $password | Should -CMatch '[0-9]'
            $password | Should -CMatch '[!#%+=?@_-]'
        }
    }

    It 'never contains characters that are easily misread' {
        # Case-sensitive on purpose. Lowercase 'l' and uppercase 'I' and 'O'
        # are excluded from the alphabet; uppercase 'L' and lowercase 'i' are
        # not confusable and are deliberately allowed.
        1..50 | ForEach-Object {
            New-OnboardTempPassword -Length 20 | Should -Not -CMatch '[0O1lI]'
        }
    }

    It 'produces a different password every time' {
        $passwords = 1..100 | ForEach-Object { New-OnboardTempPassword -Length 16 }
        ($passwords | Select-Object -Unique).Count | Should -Be 100
    }

    It 'rejects a length below the minimum' {
        { New-OnboardTempPassword -Length 4 } | Should -Throw
    }
}


Describe 'Import-OnboardKitConfig' {

    BeforeAll {
        $script:ValidConfig = @'
@{
    Domain          = 'example.com'
    AliasTemplate   = '{first:1}{last}'
    DefaultTargetOU = 'OU=Users,DC=example,DC=com'
}
'@
    }

    It 'throws a helpful error when the file does not exist' {
        { Import-OnboardKitConfig -ConfigPath 'TestDrive:\nope.psd1' } |
            Should -Throw -ExpectedMessage '*Could not find a configuration file*'
    }

    It 'loads a valid config' {
        $path = Join-Path $TestDrive 'valid.psd1'
        Set-Content -Path $path -Value $script:ValidConfig -Encoding UTF8

        $config = Import-OnboardKitConfig -ConfigPath $path

        $config.Domain          | Should -Be 'example.com'
        $config.AliasTemplate   | Should -Be '{first:1}{last}'
        $config.DefaultTargetOU | Should -Be 'OU=Users,DC=example,DC=com'
    }

    It 'records where the config was loaded from' {
        $path = Join-Path $TestDrive 'valid.psd1'
        Set-Content -Path $path -Value $script:ValidConfig -Encoding UTF8

        (Import-OnboardKitConfig -ConfigPath $path).ConfigPath | Should -Be $path
    }

    It 'fills in defaults for the optional settings' {
        $path = Join-Path $TestDrive 'valid.psd1'
        Set-Content -Path $path -Value $script:ValidConfig -Encoding UTF8

        $config = Import-OnboardKitConfig -ConfigPath $path

        $config.DefaultGroups          | Should -BeNullOrEmpty
        $config.AdSyncServer           | Should -Be ''
        $config.TempPasswordLength     | Should -Be 16
        $config.Licensing.GroupNames   | Should -BeNullOrEmpty
        $config.Graph.AuthMode         | Should -Be 'Delegated'
        $config.Graph.ClientId         | Should -Be ''
    }

    It 'names the missing setting when one is absent' {
        $path = Join-Path $TestDrive 'incomplete.psd1'
        Set-Content -Path $path -Encoding UTF8 -Value @'
@{
    Domain = 'example.com'
}
'@
        { Import-OnboardKitConfig -ConfigPath $path } |
            Should -Throw -ExpectedMessage '*AliasTemplate*'
    }

    It 'treats an empty required setting as missing' {
        $path = Join-Path $TestDrive 'empty.psd1'
        Set-Content -Path $path -Encoding UTF8 -Value @'
@{
    Domain          = ''
    AliasTemplate   = '{first:1}{last}'
    DefaultTargetOU = 'OU=Users,DC=example,DC=com'
}
'@
        { Import-OnboardKitConfig -ConfigPath $path } |
            Should -Throw -ExpectedMessage '*Domain*'
    }

    It 'explains itself when the file has a syntax error' {
        $path = Join-Path $TestDrive 'broken.psd1'
        Set-Content -Path $path -Encoding UTF8 -Value "@{ Domain = 'example.com'"

        { Import-OnboardKitConfig -ConfigPath $path } |
            Should -Throw -ExpectedMessage '*could not be read*'
    }
}


Describe 'Test-OnboardLicensingGroup' {

    BeforeAll {
        # Fabricates a group object shaped like one from Get-MgGroup. Defaults
        # describe a healthy, usable licensing group; each test overrides only
        # the one property it cares about.
        function New-TestGroup {
            param(
                $DisplayName           = 'LIC-M365-E3',
                $OnPremisesSyncEnabled = $null,
                $GroupTypes            = @(),
                $SecurityEnabled       = $true,
                $MailEnabled           = $false,
                $AssignedLicenses      = @(@{ SkuId = '05e9a617-0261-4cee-bb44-138d3ef5d965' })
            )

            [pscustomobject]@{
                Id                    = '00000000-0000-0000-0000-000000000001'
                DisplayName           = $DisplayName
                OnPremisesSyncEnabled = $OnPremisesSyncEnabled
                GroupTypes            = $GroupTypes
                SecurityEnabled       = $SecurityEnabled
                MailEnabled           = $MailEnabled
                AssignedLicenses      = $AssignedLicenses
            }
        }
    }

    Context 'a healthy group' {

        It 'accepts a cloud security group with a licence attached' {
            $verdict = Test-OnboardLicensingGroup -Group (New-TestGroup)

            $verdict.IsUsable          | Should -BeTrue
            $verdict.Problems.Count    | Should -Be 0
            $verdict.Warnings.Count    | Should -Be 0
            $verdict.GroupName         | Should -Be 'LIC-M365-E3'
        }

        It 'accepts a Microsoft 365 (Unified) group even though it is not security-enabled' {
            $group = New-TestGroup -GroupTypes @('Unified') -SecurityEnabled $false -MailEnabled $true

            (Test-OnboardLicensingGroup -Group $group).IsUsable | Should -BeTrue
        }
    }

    Context 'synced from on-premises Active Directory' {

        It 'blocks a group that is currently synced' {
            $verdict = Test-OnboardLicensingGroup -Group (New-TestGroup -OnPremisesSyncEnabled $true)

            $verdict.IsUsable                  | Should -BeFalse
            $verdict.Problems.Code             | Should -Contain 'SyncedFromOnPrem'
            $verdict.Problems[0].Fix           | Should -Match 'entra\.microsoft\.com'
        }

        # Graph reports null for a group that has never synced. Treating that
        # as "synced" would block every correctly-created cloud group, so this
        # is the case most worth pinning down.
        It 'allows a cloud-only group, which reports null rather than false' {
            $verdict = Test-OnboardLicensingGroup -Group (New-TestGroup -OnPremisesSyncEnabled $null)

            $verdict.IsUsable      | Should -BeTrue
            $verdict.Problems.Code | Should -Not -Contain 'SyncedFromOnPrem'
        }

        It 'allows a group that used to sync but no longer does' {
            $verdict = Test-OnboardLicensingGroup -Group (New-TestGroup -OnPremisesSyncEnabled $false)

            $verdict.IsUsable | Should -BeTrue
        }
    }

    Context 'membership that cannot be assigned by hand' {

        It 'blocks a dynamic group' {
            $verdict = Test-OnboardLicensingGroup -Group (New-TestGroup -GroupTypes @('DynamicMembership'))

            $verdict.IsUsable      | Should -BeFalse
            $verdict.Problems.Code | Should -Contain 'DynamicMembership'
        }

        It 'blocks a distribution group' {
            $group = New-TestGroup -SecurityEnabled $false -MailEnabled $true

            $verdict = Test-OnboardLicensingGroup -Group $group

            $verdict.IsUsable      | Should -BeFalse
            $verdict.Problems.Code | Should -Contain 'NotMemberManageable'
            ($verdict.Problems | Where-Object Code -eq 'NotMemberManageable').Message |
                Should -Match 'distribution group'
        }

        It 'does not guess when securityEnabled was never returned' {
            # A null securityEnabled means the property was not selected, not
            # that the group is unusable. Guessing here would block a good group.
            $group = New-TestGroup -SecurityEnabled $null

            (Test-OnboardLicensingGroup -Group $group).IsUsable | Should -BeTrue
        }
    }

    Context 'no licence attached' {

        It 'warns but does not block when assignedLicenses is empty' {
            $verdict = Test-OnboardLicensingGroup -Group (New-TestGroup -AssignedLicenses @())

            $verdict.IsUsable       | Should -BeTrue
            $verdict.Problems.Count | Should -Be 0
            $verdict.Warnings.Code  | Should -Contain 'NoLicensesAssigned'
        }

        It 'warns when assignedLicenses is absent entirely' {
            $verdict = Test-OnboardLicensingGroup -Group (New-TestGroup -AssignedLicenses $null)

            $verdict.Warnings.Code | Should -Contain 'NoLicensesAssigned'
        }
    }

    Context 'robustness' {

        It 'does not throw on an object missing all the properties it reads' {
            # StrictMode makes reading an absent property an error, and Graph
            # objects vary with whatever was selected.
            { Test-OnboardLicensingGroup -Group ([pscustomobject]@{ Id = 'abc' }) } |
                Should -Not -Throw
        }

        It 'falls back to a placeholder name when displayName is missing' {
            $verdict = Test-OnboardLicensingGroup -Group ([pscustomobject]@{ Id = 'abc' })

            $verdict.GroupName | Should -Be '(unnamed group)'
        }

        It 'reports every problem at once rather than stopping at the first' {
            $group = New-TestGroup -OnPremisesSyncEnabled $true -GroupTypes @('DynamicMembership')

            $verdict = Test-OnboardLicensingGroup -Group $group

            $verdict.Problems.Count | Should -Be 2
            $verdict.Problems.Code  | Should -Contain 'SyncedFromOnPrem'
            $verdict.Problems.Code  | Should -Contain 'DynamicMembership'
        }

        It 'gives every problem and warning a code, a message and a fix' {
            $group = New-TestGroup -OnPremisesSyncEnabled $true -AssignedLicenses @()

            $verdict = Test-OnboardLicensingGroup -Group $group

            foreach ($item in @($verdict.Problems) + @($verdict.Warnings)) {
                $item.Code    | Should -Not -BeNullOrEmpty
                $item.Message | Should -Not -BeNullOrEmpty
                $item.Fix     | Should -Not -BeNullOrEmpty
            }
        }
    }
}


Describe 'config.example.psd1' {

    It 'is present in the repository' {
        Join-Path (Split-Path -Parent $PSScriptRoot) 'config.example.psd1' |
            Should -Exist
    }

    It 'parses and contains every setting the toolkit reads' {
        $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'config.example.psd1'
        $example = Import-PowerShellDataFile -LiteralPath $path

        foreach ($key in @('Domain', 'AliasTemplate', 'DefaultTargetOU', 'DefaultGroups',
                           'AdSyncServer', 'TempPasswordLength', 'Licensing', 'Graph')) {
            $example.ContainsKey($key) | Should -BeTrue -Because "config.example.psd1 should document '$key'"
        }
    }

    It 'contains no real-looking secrets' {
        $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'config.example.psd1'
        $example = Import-PowerShellDataFile -LiteralPath $path

        $example.Graph.ClientSecretEnvVar     | Should -Be ''
        $example.Graph.CertificateThumbprint  | Should -Be ''
        $example.Graph.TenantId               | Should -Be '00000000-0000-0000-0000-000000000000'
    }
}
