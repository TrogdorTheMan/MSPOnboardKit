#Requires -Version 5.1

<#
.SYNOPSIS
    Checks that MSPOnboardKit is set up correctly, before you use it for real.

.DESCRIPTION
    Run this after following docs/SETUP.md. It goes through everything the
    toolkit needs and prints a simple pass/fail list, telling you exactly how
    to fix anything that is wrong.

    It only reads. It never creates, changes or deletes anything.

    By default it checks the Active Directory side only, because checking the
    Microsoft 365 side opens a sign-in window. Add -IncludeCloud when you are
    ready to check that too.

.PARAMETER IncludeCloud
    Also check the Microsoft 365 side. This will open a sign-in window and
    ask you to log in.

.PARAMETER ConfigPath
    Optional. Path to a config file. Defaults to config.psd1 next to this
    script.

.EXAMPLE
    .\Test-OnboardKitSetup.ps1

    Checks everything on the Active Directory side.

.EXAMPLE
    .\Test-OnboardKitSetup.ps1 -IncludeCloud

    Also signs in to Microsoft 365 and checks the licensing groups.

.NOTES
    MSPOnboardKit
    Copyright (C) 2026 Cory "TrogdorTheMan" Francis

    This program is free software: you can redistribute it and/or modify it
    under the terms of the GNU Affero General Public License as published by
    the Free Software Foundation, either version 3 of the License, or (at
    your option) any later version.

    This program is distributed in the hope that it will be useful, but
    WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero
    General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program. If not, see <https://www.gnu.org/licenses/>.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch] $IncludeCloud,

    [Parameter()]
    [string] $ConfigPath
)

Set-StrictMode -Version Latest

# Deliberately NOT 'Stop': this script's whole job is to survive broken
# setups and report on them, so each check handles its own errors.
$ErrorActionPreference = 'Continue'

$script:Results = New-Object System.Collections.Generic.List[object]


# Some failures - Kerberos ones especially - put the useful detail in an inner
# exception and leave "see inner exception" on the outside. Walk the chain so
# the person running this actually gets told what went wrong.
function Get-ExceptionDetail {
    param(
        [Parameter(Mandatory)][System.Exception] $Exception
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $current = $Exception
    $depth = 0

    while ($current -and $depth -lt 5) {
        $text = $current.Message.Trim()
        if ($text -and -not $lines.Contains($text)) {
            $lines.Add($text)
        }
        $current = $current.InnerException
        $depth++
    }

    $lines -join "`n"
}

function Add-Result {
    param(
        [Parameter(Mandatory)][string] $Check,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Fail', 'Warn', 'Skip')][string] $Status,
        [Parameter(Mandatory)][string] $Message,
        [string] $Fix
    )

    $script:Results.Add([pscustomobject]@{
        Check   = $Check
        Status  = $Status
        Message = $Message
        Fix     = $Fix
    })

    $colour, $label = switch ($Status) {
        'Pass' { 'Green',      '[ PASS ]' }
        'Fail' { 'Red',        '[ FAIL ]' }
        'Warn' { 'Yellow',     '[ WARN ]' }
        'Skip' { 'DarkGray',   '[ SKIP ]' }
    }

    Write-Host "$label " -ForegroundColor $colour -NoNewline
    Write-Host "$Check" -NoNewline
    Write-Host " - $Message" -ForegroundColor DarkGray

    if ($Fix -and $Status -in @('Fail', 'Warn')) {
        foreach ($line in ($Fix -split "`r?`n")) {
            Write-Host "         $line" -ForegroundColor Yellow
        }
    }
}


Write-Host ''
Write-Host '=========================================================' -ForegroundColor White
Write-Host ' MSPOnboardKit - setup check' -ForegroundColor White
Write-Host '=========================================================' -ForegroundColor White
Write-Host ' This only reads. Nothing will be created or changed.' -ForegroundColor DarkGray
Write-Host ''


#region 1. PowerShell and environment ----------------------------------------

Write-Host '--- Your computer ---' -ForegroundColor Cyan

$psVersion = $PSVersionTable.PSVersion

if ($psVersion.Major -ge 7) {
    Add-Result -Check 'PowerShell version' -Status 'Pass' -Message "$psVersion"
}
elseif ($psVersion.Major -eq 5 -and $psVersion.Minor -ge 1) {
    Add-Result -Check 'PowerShell version' -Status 'Pass' -Message "$psVersion (fine for creating users)"
    Add-Result -Check 'PowerShell 7' -Status 'Warn' `
        -Message 'Not installed. Recommended for the licensing step.' `
        -Fix "Install it with:`n    winget install --id Microsoft.PowerShell --source winget"
}
else {
    Add-Result -Check 'PowerShell version' -Status 'Fail' `
        -Message "$psVersion is too old. 5.1 or newer is required." `
        -Fix 'Update Windows, or install PowerShell 7.'
}

$executionPolicy = Get-ExecutionPolicy

if ($executionPolicy -in @('Restricted', 'AllSigned')) {
    Add-Result -Check 'Execution policy' -Status 'Fail' `
        -Message "'$executionPolicy' will block these scripts from running." `
        -Fix "Run this once:`n    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`nThis is the single most common thing that stops these scripts working."
}
else {
    Add-Result -Check 'Execution policy' -Status 'Pass' -Message "$executionPolicy"
}

#endregion


#region 2. Required modules --------------------------------------------------

Write-Host ''
Write-Host '--- Required software ---' -ForegroundColor Cyan

$adModuleAvailable = [bool](Get-Module -ListAvailable -Name ActiveDirectory)

if ($adModuleAvailable) {
    Add-Result -Check 'ActiveDirectory module' -Status 'Pass' -Message 'Installed.'
}
else {
    Add-Result -Check 'ActiveDirectory module' -Status 'Fail' `
        -Message 'Not installed. New-OnboardUser.ps1 cannot run without it.' `
        -Fix @"
On Windows 10/11, run in an ELEVATED WINDOWS POWERSHELL 5.1 window:
    Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
PowerShell 7 fails this with "Class not registered". From any shell use:
    DISM.exe /Online /Add-Capability /CapabilityName:Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
A reboot may be needed before the module loads. Check state with:
    Get-WindowsCapability -Online -Name 'Rsat.ActiveDirectory*' | Select-Object Name, State
On a server:
    Install-WindowsFeature RSAT-AD-PowerShell
See docs/SETUP.md section 3.2.
"@
}

$graphModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Users', 'Microsoft.Graph.Groups')
$missingGraph = @($graphModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) })

if ($missingGraph.Count -eq 0) {
    Add-Result -Check 'Microsoft Graph modules' -Status 'Pass' -Message 'Installed.'
}
else {
    Add-Result -Check 'Microsoft Graph modules' -Status 'Fail' `
        -Message "Missing: $($missingGraph -join ', ')" `
        -Fix "Run:`n    Install-Module Microsoft.Graph -Scope CurrentUser`nIt is a large download and can take several minutes."
}

#endregion


#region 3. Configuration file ------------------------------------------------

Write-Host ''
Write-Host '--- Your configuration file ---' -ForegroundColor Cyan

$config = $null

try {
    Import-Module (Join-Path $PSScriptRoot 'OnboardKit\OnboardKit.psd1') -Force -ErrorAction Stop
    $config = Import-OnboardKitConfig -ConfigPath $ConfigPath -ErrorAction Stop
    Add-Result -Check 'config.psd1' -Status 'Pass' -Message "Loaded from $($config.ConfigPath)"
}
catch {
    Add-Result -Check 'config.psd1' -Status 'Fail' `
        -Message 'Could not be loaded.' `
        -Fix ($_.Exception.Message)
}

if ($config) {

    Add-Result -Check 'Domain' -Status 'Pass' -Message $config.Domain

    try {
        $sampleAlias = ConvertTo-OnboardAlias -FirstName 'John' -LastName 'Smith' -Template $config.AliasTemplate
        Add-Result -Check 'AliasTemplate' -Status 'Pass' `
            -Message "'$($config.AliasTemplate)' - a new hire named John Smith would get $sampleAlias@$($config.Domain)"
    }
    catch {
        Add-Result -Check 'AliasTemplate' -Status 'Fail' `
            -Message "'$($config.AliasTemplate)' is not valid." `
            -Fix ($_.Exception.Message)
    }

    if ($config.DefaultGroups.Count -gt 0) {
        Add-Result -Check 'DefaultGroups' -Status 'Pass' -Message ($config.DefaultGroups -join ', ')
    }
    else {
        Add-Result -Check 'DefaultGroups' -Status 'Warn' `
            -Message 'Empty. A new hire created without -MirrorUser will get no groups.' `
            -Fix 'That is fine if you always use -MirrorUser. Otherwise list your baseline groups in config.psd1.'
    }

    if ($config.Licensing.GroupNames.Count -gt 0) {
        Add-Result -Check 'Licensing groups' -Status 'Pass' -Message ($config.Licensing.GroupNames -join ', ')
    }
    else {
        Add-Result -Check 'Licensing groups' -Status 'Fail' `
            -Message 'None configured. Add-OnboardUserLicense.ps1 will not run.' `
            -Fix 'List your license-bearing Entra ID groups under Licensing.GroupNames in config.psd1.'
    }

    if ($config.Graph.AuthMode -in @('Delegated', 'AppRegistration')) {
        Add-Result -Check 'Graph.AuthMode' -Status 'Pass' -Message $config.Graph.AuthMode
    }
    else {
        Add-Result -Check 'Graph.AuthMode' -Status 'Fail' `
            -Message "'$($config.Graph.AuthMode)' is not valid." `
            -Fix "It must be exactly 'Delegated' or 'AppRegistration'."
    }
}

#endregion


#region 4. Active Directory --------------------------------------------------

Write-Host ''
Write-Host '--- Active Directory ---' -ForegroundColor Cyan

if (-not $adModuleAvailable) {
    Add-Result -Check 'Active Directory checks' -Status 'Skip' -Message 'The ActiveDirectory module is not installed.'
}
elseif (-not $config) {
    Add-Result -Check 'Active Directory checks' -Status 'Skip' -Message 'The config file could not be loaded.'
}
else {

    Import-Module ActiveDirectory -ErrorAction SilentlyContinue

    # Every AD lookup below gets these. Empty when Server is not configured,
    # which leaves behaviour on a domain-joined machine exactly as it was.
    $adCommon = @{}
    if ($config.Server) {
        $adCommon['Server'] = $config.Server
    }

    $domainReachable = $false

    try {
        $adDomain = Get-ADDomain @adCommon -ErrorAction Stop
        $domainReachable = $true
        Add-Result -Check 'Domain reachable' -Status 'Pass' -Message $adDomain.DNSRoot
    }
    catch {
        Add-Result -Check 'Domain reachable' -Status 'Fail' `
            -Message 'Could not contact Active Directory.' `
            -Fix "Are you on the company network or VPN, and signed in with a domain account?`n$(Get-ExceptionDetail -Exception $_.Exception)"
    }

    if ($domainReachable) {

        try {
            $null = Get-ADOrganizationalUnit -Identity $config.DefaultTargetOU @adCommon -ErrorAction Stop
            Add-Result -Check 'DefaultTargetOU' -Status 'Pass' -Message $config.DefaultTargetOU
        }
        catch {
            Add-Result -Check 'DefaultTargetOU' -Status 'Fail' `
                -Message "Not found: $($config.DefaultTargetOU)" `
                -Fix "This must be the OU's exact distinguished name. See docs/SETUP.md section 6 for how to copy it out of Active Directory Users and Computers."
        }

        foreach ($protectedOu in $config.ProtectedOUs) {
            try {
                $null = Get-ADOrganizationalUnit -Identity $protectedOu @adCommon -ErrorAction Stop
                Add-Result -Check "ProtectedOU '$protectedOu'" -Status 'Pass' -Message 'Exists.'
            }
            catch {
                # A typo here protects nothing while looking like it does,
                # which is the worst way for a guard to fail.
                Add-Result -Check "ProtectedOU '$protectedOu'" -Status 'Fail' `
                    -Message 'This OU does not exist, so nothing is actually being protected by this entry.' `
                    -Fix "Correct the entry in ProtectedOUs in your config file, or remove it. It must be the OU's exact distinguished name."
            }
        }

        # Is the email domain usable as a sign-in suffix at all?
        try {
            $adForest = Get-ADForest @adCommon -ErrorAction Stop

            $validSuffixes = @($adForest.UPNSuffixes) + @($adDomain.DNSRoot) + @($adForest.RootDomain) |
                Where-Object { $_ } |
                ForEach-Object { $_.ToLowerInvariant() }

            if ($config.Domain.ToLowerInvariant() -in $validSuffixes) {
                Add-Result -Check 'UPN suffix' -Status 'Pass' -Message "'$($config.Domain)' is available as a sign-in suffix."
            }
            else {
                Add-Result -Check 'UPN suffix' -Status 'Fail' `
                    -Message "'$($config.Domain)' is not registered as a sign-in (UPN) suffix in this forest." `
                    -Fix @"
Accounts cannot be created with a sign-in name ending in @$($config.Domain)
until it is registered.

A domain administrator adds it in:
    Active Directory Domains and Trusts  >  right-click the root  >
    Properties  >  UPN Suffixes  >  Add

Suffixes currently available: $($validSuffixes -join ', ')
"@
            }
        }
        catch {
            Add-Result -Check 'UPN suffix' -Status 'Warn' `
                -Message 'Could not read the forest configuration to check this.' -Fix $_.Exception.Message
        }

        # Compared against the mail attribute, not the sign-in name. Domain in
        # the config drives the email address as well as the sign-in name, so
        # "what domain is their email on" is the question that matters. Sign-in
        # names are reported separately and never used as a recommendation:
        # they are frequently inconsistent in long-lived domains, and the
        # majority answer there can easily be an internal name that would be
        # actively wrong to put in an email address.
        try {
            $sampleUsers = @(
                Get-ADUser -SearchBase $config.DefaultTargetOU -Filter 'Enabled -eq $true' `
                    -Properties UserPrincipalName, mail -ResultSetSize 200 @adCommon -ErrorAction Stop |
                    Where-Object { $_.mail }
            )

            if ($sampleUsers.Count -eq 0) {
                Add-Result -Check 'Existing email domain' -Status 'Skip' `
                    -Message 'No existing enabled users with an email address in the target OU to compare against.'
            }
            else {
                $mailDomains = $sampleUsers |
                    ForEach-Object { ($_.mail -split '@')[-1].ToLowerInvariant() } |
                    Group-Object | Sort-Object Count -Descending

                $mailSummary = ($mailDomains | ForEach-Object { "@$($_.Name) x$($_.Count)" }) -join ', '

                if ($mailDomains[0].Name -eq $config.Domain.ToLowerInvariant()) {
                    Add-Result -Check 'Existing email domain' -Status 'Pass' `
                        -Message "Existing staff use @$($mailDomains[0].Name), matching your config ($mailSummary)."
                }
                else {
                    Add-Result -Check 'Existing email domain' -Status 'Warn' `
                        -Message "Existing staff use @$($mailDomains[0].Name), but new hires would get @$($config.Domain)." `
                        -Fix "Found in the target OU: $mailSummary`nCheck the Domain setting in your config file is the domain your staff actually receive email on."
                }

                # Informational only.
                $upnSuffixes = $sampleUsers |
                    Where-Object { $_.UserPrincipalName } |
                    ForEach-Object { ($_.UserPrincipalName -split '@')[-1].ToLowerInvariant() } |
                    Group-Object | Sort-Object Count -Descending

                if ($upnSuffixes.Count -gt 1) {
                    $upnSummary = ($upnSuffixes | ForEach-Object { "@$($_.Name) x$($_.Count)" }) -join ', '
                    Add-Result -Check 'Existing sign-in names' -Status 'Warn' `
                        -Message "Existing staff sign in with more than one suffix: $upnSummary" `
                        -Fix @"
There is no single existing convention here to copy, which is common in domains
that have been running for a long time under several administrators.

New accounts will be created as @$($config.Domain), which is the right choice
as long as that is a real, routable domain - an internal-only name such as
.lan or .local cannot be used to sign in to Microsoft 365.

Nothing to fix in this toolkit. Worth asking whoever manages Entra Connect
which attribute it uses as the sign-in name, since existing users on the other
suffix must be getting it from somewhere.
"@
                }
            }
        }
        catch {
            Add-Result -Check 'Existing email domain' -Status 'Skip' `
                -Message "Could not sample existing users: $($_.Exception.Message)"
        }

        foreach ($groupName in $config.DefaultGroups) {
            try {
                $null = Get-ADGroup -Identity $groupName @adCommon -ErrorAction Stop
                Add-Result -Check "Group '$groupName'" -Status 'Pass' -Message 'Exists.'
            }
            catch {
                Add-Result -Check "Group '$groupName'" -Status 'Fail' `
                    -Message 'Not found in Active Directory.' `
                    -Fix 'Check the spelling in DefaultGroups in your config file.'
            }
        }

        # Permission probe: can this account see the OU's security descriptor?
        # A read is enough to tell "you have rights here" from "you do not",
        # without creating anything.
        try {
            $ouAcl = Get-Acl -Path "AD:\$($config.DefaultTargetOU)" -ErrorAction Stop
            if ($ouAcl) {
                Add-Result -Check 'OU permissions readable' -Status 'Pass' `
                    -Message 'You can read the target OU. This does not guarantee you can create users in it.'
            }
        }
        catch {
            Add-Result -Check 'OU permissions readable' -Status 'Warn' `
                -Message 'Could not read the target OU permissions.' `
                -Fix 'You may not have the rights to create users there. See docs/SETUP.md section 2.'
        }
    }

    # Directory sync
    if ($config.AdSyncServer) {
        try {
            $remoteHasAdSync = Invoke-Command -ComputerName $config.AdSyncServer -ScriptBlock {
                [bool](Get-Module -ListAvailable -Name ADSync)
            } -ErrorAction Stop

            if ($remoteHasAdSync) {
                Add-Result -Check 'Directory sync' -Status 'Pass' -Message "Entra Connect found on $($config.AdSyncServer)."
            }
            else {
                Add-Result -Check 'Directory sync' -Status 'Fail' `
                    -Message "Reached $($config.AdSyncServer), but Entra Connect is not installed there." `
                    -Fix 'Correct AdSyncServer in your config file, or set it to empty and use -SkipSync.'
            }
        }
        catch {
            Add-Result -Check 'Directory sync' -Status 'Fail' `
                -Message "Could not reach $($config.AdSyncServer)." `
                -Fix "PowerShell remoting may not be enabled on that server.`n$($_.Exception.Message)"
        }
    }
    elseif (Get-Module -ListAvailable -Name ADSync) {
        Add-Result -Check 'Directory sync' -Status 'Pass' -Message 'Entra Connect is installed on this machine.'
    }
    else {
        Add-Result -Check 'Directory sync' -Status 'Warn' `
            -Message 'Entra Connect is not on this machine and AdSyncServer is not set.' `
            -Fix "New-OnboardUser.ps1 will still create accounts, but cannot trigger a sync.`nEither set AdSyncServer in config.psd1, or use -SkipSync and let the automatic 30 minute sync handle it."
    }
}

#endregion


#region 5. Microsoft 365 -----------------------------------------------------

Write-Host ''
Write-Host '--- Microsoft 365 ---' -ForegroundColor Cyan

if (-not $IncludeCloud) {
    Add-Result -Check 'Microsoft 365 checks' -Status 'Skip' `
        -Message 'Not checked. Re-run with -IncludeCloud to sign in and check these.'
}
elseif ($missingGraph.Count -gt 0) {
    Add-Result -Check 'Microsoft 365 checks' -Status 'Skip' -Message 'The Microsoft Graph modules are not installed.'
}
elseif (-not $config) {
    Add-Result -Check 'Microsoft 365 checks' -Status 'Skip' -Message 'The config file could not be loaded.'
}
else {

    try {
        foreach ($module in $graphModules) {
            Import-Module $module -ErrorAction Stop
        }

        $connectParams = @{ ErrorAction = 'Stop' }
        if ($config.Graph.TenantId) {
            $connectParams['TenantId'] = $config.Graph.TenantId
        }
        if ((Get-Command Connect-MgGraph).Parameters.ContainsKey('NoWelcome')) {
            $connectParams['NoWelcome'] = $true
        }
        # Read-only scopes: this script never changes anything.
        $connectParams['Scopes'] = @('User.Read.All', 'Group.Read.All')

        Write-Host '         A sign-in window will open now...' -ForegroundColor Yellow
        Connect-MgGraph @connectParams | Out-Null

        $context = Get-MgContext
        Add-Result -Check 'Microsoft 365 sign-in' -Status 'Pass' -Message "Tenant $($context.TenantId)"

        foreach ($groupName in $config.Licensing.GroupNames) {
            $escapedName = $groupName -replace "'", "''"

            # assignedLicenses is not returned unless explicitly selected, and
            # selecting anything means selecting everything needed.
            $group = @(Get-MgGroup -Filter "displayName eq '$escapedName'" -ErrorAction SilentlyContinue `
                           -Property 'id,displayName,onPremisesSyncEnabled,groupTypes,securityEnabled,mailEnabled,assignedLicenses') |
                Select-Object -First 1

            if (-not $group) {
                Add-Result -Check "Licensing group '$groupName'" -Status 'Fail' `
                    -Message 'No group with this exact display name exists in Entra ID.' `
                    -Fix "Check the spelling in config.psd1. If the group does not exist yet, a tenant administrator needs to create it and assign the license SKUs. See docs/SETUP.md section 5."
                continue
            }

            # Catching an unusable group here - at setup time - is the whole
            # point. The alternative is discovering it mid-onboarding.
            $verdict = Test-OnboardLicensingGroup -Group $group

            if ($verdict.IsUsable -and $verdict.Warnings.Count -eq 0) {
                Add-Result -Check "Licensing group '$groupName'" -Status 'Pass' -Message "Found and usable (id $($group.Id))."
            }

            foreach ($problem in $verdict.Problems) {
                Add-Result -Check "Licensing group '$groupName'" -Status 'Fail' `
                    -Message $problem.Message -Fix $problem.Fix
            }

            foreach ($warning in $verdict.Warnings) {
                Add-Result -Check "Licensing group '$groupName'" -Status 'Warn' `
                    -Message $warning.Message -Fix $warning.Fix
            }
        }
    }
    catch {
        Add-Result -Check 'Microsoft 365 sign-in' -Status 'Fail' `
            -Message 'Could not sign in or read groups.' `
            -Fix ($_.Exception.Message)
    }
}

#endregion


#region Summary --------------------------------------------------------------

$passed  = @($script:Results | Where-Object Status -eq 'Pass').Count
$failed  = @($script:Results | Where-Object Status -eq 'Fail').Count
$warned  = @($script:Results | Where-Object Status -eq 'Warn').Count
$skipped = @($script:Results | Where-Object Status -eq 'Skip').Count

Write-Host ''
Write-Host '=========================================================' -ForegroundColor White
Write-Host ' RESULT' -ForegroundColor White
Write-Host '=========================================================' -ForegroundColor White
Write-Host " Passed:  $passed" -ForegroundColor Green
Write-Host " Failed:  $failed" -ForegroundColor $(if ($failed) { 'Red' } else { 'DarkGray' })
Write-Host " Warning: $warned" -ForegroundColor $(if ($warned) { 'Yellow' } else { 'DarkGray' })
Write-Host " Skipped: $skipped" -ForegroundColor DarkGray
Write-Host ''

if ($failed -gt 0) {
    Write-Host ' Not ready yet. Fix the FAIL items above, then run this again.' -ForegroundColor Red
    Write-Host ' Every FAIL has instructions underneath it in yellow.' -ForegroundColor DarkGray
}
elseif ($warned -gt 0) {
    Write-Host ' Good enough to use. The warnings above are worth reading first.' -ForegroundColor Yellow
}
else {
    Write-Host ' All good. You are ready to go.' -ForegroundColor Green
    Write-Host ''
    Write-Host ' Try a dry run next:' -ForegroundColor DarkGray
    Write-Host '     .\New-OnboardUser.ps1 -FirstName Test -LastName User -WhatIf' -ForegroundColor White
}
Write-Host ''

#endregion
