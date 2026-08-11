#Requires -Version 5.1

<#
.SYNOPSIS
    Assigns a Microsoft 365 license to a new hire by adding them to the
    licensing group(s) in your config file.

.DESCRIPTION
    This is step 2 of 2. Run it after New-OnboardUser.ps1, once the account
    has finished syncing from Active Directory up to Microsoft 365.

    It does not assign licenses directly. Instead it adds the user to Entra ID
    group(s) that already carry the license, which is Microsoft's recommended
    "group-based licensing" approach - the license follows group membership.

    IMPORTANT: those groups must already exist and already have license SKUs
    assigned to them. That is a one-time setup job for whoever administers
    your Microsoft 365 tenant. This script does not create them.
    See docs/SETUP.md section 5.

    Safe to run more than once. If the user is already in a group, it says so
    and moves on.

.PARAMETER UserPrincipalName
    The new hire's full email address, for example jsmith@contoso.com.
    New-OnboardUser.ps1 prints the exact command to run, including this.

.PARAMETER Wait
    Wait for the account to appear in Microsoft 365 instead of giving up
    straight away. Useful if you run this immediately after creating the
    account.

.PARAMETER TimeoutMinutes
    How long to wait when -Wait is used. Default 30.

.PARAMETER PollSeconds
    How often to check when -Wait is used. Default 60.

.PARAMETER ConfigPath
    Optional. Path to a config file. Defaults to config.psd1 next to this
    script.

.PARAMETER PassThru
    Optional. Also return the run summary as an object, for scripting.

.EXAMPLE
    .\Add-OnboardUserLicense.ps1 -UserPrincipalName jsmith@contoso.com -WhatIf

    Shows what would happen without changing anything.

.EXAMPLE
    .\Add-OnboardUserLicense.ps1 -UserPrincipalName jsmith@contoso.com

    Adds the user to the licensing groups from config.psd1.

.EXAMPLE
    .\Add-OnboardUserLicense.ps1 -UserPrincipalName jsmith@contoso.com -Wait

    Waits (up to 30 minutes) for the account to finish syncing, then assigns
    the license.

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

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $UserPrincipalName,

    [Parameter()]
    [switch] $Wait,

    [Parameter()]
    [ValidateRange(1, 480)]
    [int] $TimeoutMinutes = 30,

    [Parameter()]
    [ValidateRange(10, 900)]
    [int] $PollSeconds = 60,

    [Parameter()]
    [string] $ConfigPath,

    [Parameter()]
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'OnboardKit\OnboardKit.psd1') -Force


#region Output helpers -------------------------------------------------------

function Write-Step {
    param([string] $Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string] $Message)
    Write-Host "    [ ok ] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string] $Message)
    Write-Host "    [warn] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string] $Message)
    Write-Host "    [FAIL] $Message" -ForegroundColor Red
}

function Write-Detail {
    param([string] $Message)
    Write-Host "           $Message" -ForegroundColor DarkGray
}

#endregion


#region Preflight ------------------------------------------------------------

$requiredGraphModules = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Users'
    'Microsoft.Graph.Groups'
)

$missingModules = @($requiredGraphModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) })

if ($missingModules.Count -gt 0) {
    throw @"
The Microsoft Graph PowerShell modules are not installed on this machine.

Missing: $($missingModules -join ', ')

To install them, run this in PowerShell (it does not need to be elevated):

    Install-Module Microsoft.Graph -Scope CurrentUser

Say yes if it asks about an untrusted repository. It is a large download and
can take several minutes.

See docs/SETUP.md section 3.
"@
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning @"
You are running Windows PowerShell $($PSVersionTable.PSVersion).
The Microsoft Graph modules work here but are noticeably slower and
occasionally hit issues. PowerShell 7 is recommended for this script.
To install it:  winget install --id Microsoft.PowerShell --source winget
"@
}

foreach ($module in $requiredGraphModules) {
    Import-Module $module -ErrorAction Stop
}

$config = Import-OnboardKitConfig -ConfigPath $ConfigPath

$licensingGroups = @($config.Licensing.GroupNames)

if ($licensingGroups.Count -eq 0) {
    throw @"
No licensing groups are configured, so there is nothing to do.

Open your config file:
    $($config.ConfigPath)

and list the Entra ID group(s) that hand out licenses, under Licensing:

    Licensing = @{
        GroupNames = @('LIC-M365-E3')
    }

These groups must already exist and already have license SKUs assigned.
See docs/SETUP.md section 5.
"@
}

Write-Host ''
Write-Host '=========================================================' -ForegroundColor White
Write-Host ' MSPOnboardKit - Microsoft 365 licensing' -ForegroundColor White
Write-Host '=========================================================' -ForegroundColor White
Write-Detail "Config file : $($config.ConfigPath)"
Write-Detail "User        : $UserPrincipalName"
Write-Detail "Groups      : $($licensingGroups -join ', ')"

if ($WhatIfPreference) {
    Write-Host ''
    Write-Host ' DRY RUN (-WhatIf): nothing will be changed.' -ForegroundColor Yellow
}

#endregion


#region Sign in to Microsoft 365 ---------------------------------------------

Write-Step "Signing in to Microsoft 365"

$graph = $config.Graph

$connectParams = @{ ErrorAction = 'Stop' }

if ($graph.TenantId) {
    $connectParams['TenantId'] = $graph.TenantId
}

# -NoWelcome only exists in newer versions of the module.
if ((Get-Command Connect-MgGraph).Parameters.ContainsKey('NoWelcome')) {
    $connectParams['NoWelcome'] = $true
}

switch ($graph.AuthMode) {

    'Delegated' {
        Write-Detail 'Mode: Delegated - a sign-in window will open.'
        Write-Detail 'Sign in with your own work account.'
        $connectParams['Scopes'] = @(
            'GroupMember.ReadWrite.All'
            'User.Read.All'
            'Group.Read.All'
        )
    }

    'AppRegistration' {
        Write-Detail 'Mode: AppRegistration - signing in as an application.'

        if (-not $graph.ClientId) {
            throw "Graph.AuthMode is 'AppRegistration' but Graph.ClientId is empty in $($config.ConfigPath)."
        }
        if (-not $graph.TenantId) {
            throw "Graph.AuthMode is 'AppRegistration' but Graph.TenantId is empty in $($config.ConfigPath)."
        }

        $connectParams['ClientId'] = $graph.ClientId

        if ($graph.CertificateThumbprint) {
            $connectParams['CertificateThumbprint'] = $graph.CertificateThumbprint
            Write-Detail "Using certificate $($graph.CertificateThumbprint)"
        }
        elseif ($graph.ClientSecretEnvVar) {

            $secret = [Environment]::GetEnvironmentVariable($graph.ClientSecretEnvVar)

            if (-not $secret) {
                throw @"
The environment variable '$($graph.ClientSecretEnvVar)' is empty or not set.

Your config file says the client secret lives in that environment variable.
Set it before running this script, for example:

    `$env:$($graph.ClientSecretEnvVar) = 'the-secret-value'

Remember: the secret itself must never be written into config.psd1.
"@
            }

            $connectParams['ClientSecretCredential'] = New-Object System.Management.Automation.PSCredential(
                $graph.ClientId,
                (ConvertTo-SecureString -String $secret -AsPlainText -Force)
            )
            Write-Detail "Using client secret from `$env:$($graph.ClientSecretEnvVar)"
        }
        else {
            throw @"
Graph.AuthMode is 'AppRegistration' but no credential is configured.

Set either of these in $($config.ConfigPath):
    Graph.CertificateThumbprint  (preferred)
    Graph.ClientSecretEnvVar     (the NAME of an environment variable holding
                                  the secret - never the secret itself)
"@
        }
    }

    default {
        throw @"
Graph.AuthMode in $($config.ConfigPath) is '$($graph.AuthMode)', which is not valid.

It must be exactly one of:
    'Delegated'        - you sign in yourself (recommended)
    'AppRegistration'  - signs in as a registered application
"@
    }
}

try {
    Connect-MgGraph @connectParams | Out-Null
    $context = Get-MgContext
    Write-Ok "Signed in to tenant $($context.TenantId)"
    if ($context.Account) {
        Write-Detail "As: $($context.Account)"
    }
}
catch {
    throw @"
Could not sign in to Microsoft 365.

Microsoft reported: $($_.Exception.Message)

Common causes:
  - You cancelled or closed the sign-in window
  - Your account does not have permission to manage group membership
  - The TenantId in your config file is wrong

See docs/SETUP.md section 11.
"@
}

#endregion


#region Find the user --------------------------------------------------------

Write-Step "Looking for the account in Microsoft 365"

function Get-OnboardCloudUser {
    param([string] $Upn)

    # -ErrorAction SilentlyContinue: an empty result is a normal, expected
    # outcome here (the account may not have synced yet), not a failure.
    $escaped = $Upn -replace "'", "''"
    return @(Get-MgUser -Filter "userPrincipalName eq '$escaped'" -ErrorAction SilentlyContinue) |
        Select-Object -First 1
}

$cloudUser = Get-OnboardCloudUser -Upn $UserPrincipalName

if (-not $cloudUser -and $Wait) {

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Detail "Not there yet. Waiting up to $TimeoutMinutes minutes, checking every $PollSeconds seconds."
    Write-Detail 'Press Ctrl+C to stop waiting.'

    while (-not $cloudUser -and (Get-Date) -lt $deadline) {

        $remaining = [int]([Math]::Max(0, ($deadline - (Get-Date)).TotalMinutes))
        Write-Detail "Still waiting... (about $remaining minutes left)"

        Start-Sleep -Seconds $PollSeconds
        $cloudUser = Get-OnboardCloudUser -Upn $UserPrincipalName
    }
}

if (-not $cloudUser) {
    throw @"
The account '$UserPrincipalName' has not appeared in Microsoft 365 yet.

This is normal if you have only just created it. Accounts are created in
Active Directory first, then copied up to Microsoft 365 by Entra Connect,
which usually takes a few minutes and can take up to 30.

What to do:
  - Wait a few minutes and run this command again, or
  - Run it with -Wait and it will keep checking by itself:

        .\Add-OnboardUserLicense.ps1 -UserPrincipalName $UserPrincipalName -Wait

If it still has not appeared after 30 minutes, the directory sync may not
have run. See docs/SETUP.md section 11.
"@
}

Write-Ok "Found: $($cloudUser.DisplayName) <$($cloudUser.UserPrincipalName)>"

#endregion


#region Add to licensing groups ----------------------------------------------

Write-Step "Adding to licensing group(s)"

# Fetched once rather than per group: one call answers "which groups is this
# user already in" for every group we care about.
$currentMembershipIds = @(
    Get-MgUserMemberOf -UserId $cloudUser.Id -All -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Id
)

$groupsAdded   = New-Object System.Collections.Generic.List[string]
$groupsSkipped = New-Object System.Collections.Generic.List[string]
$groupsFailed  = New-Object System.Collections.Generic.List[object]

foreach ($groupName in $licensingGroups) {

    $escapedName = $groupName -replace "'", "''"

    # assignedLicenses is NOT returned by default - without an explicit
    # -Property it always reads as empty, so it has to be selected here. And
    # once -Property is used, everything else needed must be listed too.
    $group = @(Get-MgGroup -Filter "displayName eq '$escapedName'" -ErrorAction SilentlyContinue `
                   -Property 'id,displayName,onPremisesSyncEnabled,groupTypes,securityEnabled,mailEnabled,assignedLicenses') |
        Select-Object -First 1

    if (-not $group) {
        $groupsFailed.Add([pscustomobject]@{
            Group  = $groupName
            Reason = 'No group with this exact display name exists in Entra ID.'
        })
        Write-Fail "'$groupName' does not exist in Entra ID."
        Write-Detail 'Check the spelling in your config file. The name must match exactly.'
        continue
    }

    # Checked before attempting the add, because the underlying failure is an
    # opaque 403 that tells the technician nothing.
    $verdict = Test-OnboardLicensingGroup -Group $group

    foreach ($warning in $verdict.Warnings) {
        Write-Warn $warning.Message
        foreach ($line in ($warning.Fix -split "`r?`n")) {
            if ($line.Trim()) { Write-Detail $line }
        }
    }

    if (-not $verdict.IsUsable) {
        $groupsFailed.Add([pscustomobject]@{
            Group  = $groupName
            Reason = ($verdict.Problems | ForEach-Object { $_.Message }) -join ' '
        })

        foreach ($problem in $verdict.Problems) {
            Write-Fail $problem.Message
            foreach ($line in ($problem.Fix -split "`r?`n")) {
                if ($line.Trim()) { Write-Detail $line }
            }
        }
        continue
    }

    if ($currentMembershipIds -contains $group.Id) {
        $groupsSkipped.Add($groupName)
        Write-Ok "Already a member of '$groupName' - nothing to do."
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($groupName, "Add $UserPrincipalName to licensing group")) {
        continue
    }

    # As with the AD group adds, one failure must not abandon the rest.
    try {
        New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $cloudUser.Id -ErrorAction Stop
        $groupsAdded.Add($groupName)
        Write-Ok "Added to '$groupName'"
    }
    catch {
        $reason = $_.Exception.Message

        # Backstop for anything the checks above did not catch. This particular
        # message is what Graph returns for a group synced from on-premises AD,
        # and on its own it means nothing to the person reading it.
        if ($reason -match 'originated within an external service') {
            $reason += " This usually means '$groupName' is synchronised from your on-premises Active Directory and cannot be changed from the cloud - see docs/SETUP.md section 5."
        }

        $groupsFailed.Add([pscustomobject]@{
            Group  = $groupName
            Reason = $reason
        })
        Write-Fail "Could not add to '$groupName': $reason"
    }
}

#endregion


#region Summary --------------------------------------------------------------

Write-Host ''
Write-Host '=========================================================' -ForegroundColor White
Write-Host ' SUMMARY' -ForegroundColor White
Write-Host '=========================================================' -ForegroundColor White

if ($WhatIfPreference) {
    Write-Host ' This was a DRY RUN. Nothing was changed.' -ForegroundColor Yellow
    Write-Host ' Re-run the same command without -WhatIf to do it for real.' -ForegroundColor Yellow
    Write-Host ''
}

Write-Host " User : $($cloudUser.DisplayName) <$UserPrincipalName>"

if ($groupsAdded.Count -gt 0) {
    Write-Host ''
    Write-Host " Added to ($($groupsAdded.Count)):"
    foreach ($name in $groupsAdded) {
        Write-Host "     - $name" -ForegroundColor Green
    }
}

if ($groupsSkipped.Count -gt 0) {
    Write-Host ''
    Write-Host " Already a member of ($($groupsSkipped.Count)):"
    foreach ($name in $groupsSkipped) {
        Write-Host "     - $name" -ForegroundColor DarkGray
    }
}

if ($groupsFailed.Count -gt 0) {
    Write-Host ''
    Write-Host " FAILED ($($groupsFailed.Count)) - assign these by hand:" -ForegroundColor Red
    foreach ($failure in $groupsFailed) {
        Write-Host "     - $($failure.Group)" -ForegroundColor Red
        Write-Host "       $($failure.Reason)" -ForegroundColor DarkGray
    }
}

Write-Host ''
if ($groupsFailed.Count -eq 0 -and -not $WhatIfPreference) {
    Write-Host ' Licensing complete.' -ForegroundColor Green
    Write-Host ' It can take a few minutes for the license to actually appear on the' -ForegroundColor DarkGray
    Write-Host ' account, and a little longer before the mailbox is ready to use.' -ForegroundColor DarkGray
}
Write-Host ''

if ($PassThru) {
    [pscustomobject][ordered]@{
        UserPrincipalName = $UserPrincipalName
        DisplayName       = $cloudUser.DisplayName
        # .ToArray(), not @( ): a generic List inside a hashtable makes the
        # [pscustomobject] cast throw "Argument types do not match" on PS 5.1.
        GroupsAdded       = $groupsAdded.ToArray()
        GroupsSkipped     = $groupsSkipped.ToArray()
        GroupsFailed      = $groupsFailed.ToArray()
        WhatIf            = [bool]$WhatIfPreference
    }
}

#endregion
