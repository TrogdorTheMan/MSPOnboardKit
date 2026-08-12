#Requires -Version 5.1

<#
.SYNOPSIS
    Creates a new-hire Active Directory account, mirrors group membership,
    and triggers a directory sync to Microsoft 365.

.DESCRIPTION
    This is step 1 of 2. It does everything on the Active Directory side:

        1. Works out the email alias from the naming template in config.psd1
        2. Makes sure that alias is not already taken, adding a number if it is
        3. Creates the account, enabled, with a random temporary password and
           "must change password at next logon" set
        4. Sets proxyAddresses correctly (one uppercase SMTP: primary address)
        5. Adds the account to groups - either copied from a mirror user, or
           the default list in config.psd1
        6. Triggers a delta directory sync so the account appears in Entra ID

    Step 2 is Add-OnboardUserLicense.ps1, which assigns the Microsoft 365
    license. It has to run separately because the account must finish syncing
    to the cloud first. This script tells you the exact command to run.

    ALWAYS run this with -WhatIf the first time. It creates real accounts.

.PARAMETER FirstName
    The new hire's first name.

.PARAMETER LastName
    The new hire's last name.

.PARAMETER MirrorUser
    Optional. The username (sAMAccountName) of an existing employee whose
    group memberships should be copied to the new hire.

    If you leave this out, the new hire is added to the DefaultGroups listed
    in config.psd1 instead.

.PARAMETER TargetOU
    Optional. Where to create the account. Defaults to DefaultTargetOU from
    config.psd1.

.PARAMETER SkipSync
    Optional. Skip the directory sync step. Use this when you are running the
    script from a machine that does not have Entra Connect installed.

.PARAMETER Server
    Optional. A specific domain controller to talk to. Defaults to whichever
    one your machine normally uses.

.PARAMETER ConfigPath
    Optional. Path to a config file. Defaults to config.psd1 next to this
    script.

.PARAMETER PassThru
    Optional. Also return the run summary as an object, for scripting.

.EXAMPLE
    .\New-OnboardUser.ps1 -FirstName John -LastName Smith -MirrorUser jdoe -WhatIf

    Shows exactly what would happen without changing anything. Always do this
    first.

.EXAMPLE
    .\New-OnboardUser.ps1 -FirstName John -LastName Smith -MirrorUser jdoe

    Creates the account, copying jdoe's group memberships.

.EXAMPLE
    .\New-OnboardUser.ps1 -FirstName John -LastName Smith

    Creates the account with only the DefaultGroups from config.psd1.

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
    [string] $FirstName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $LastName,

    [Parameter()]
    [string] $MirrorUser,

    [Parameter()]
    [string] $TargetOU,

    [Parameter()]
    [switch] $SkipSync,

    [Parameter()]
    [string] $Server,

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

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    throw @"
The ActiveDirectory PowerShell module is not installed on this machine.

This script cannot create accounts without it.

To install it on Windows 10/11, open an elevated WINDOWS POWERSHELL 5.1 window
(not PowerShell 7 - the command fails there with "Class not registered") and run:
    Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

From any shell, including PowerShell 7, this works instead (still elevated):
    DISM.exe /Online /Add-Capability /CapabilityName:Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

Or via the GUI:
    Settings > System > Optional features > View features
    then search for and install "RSAT: Active Directory Domain Services and
    Lightweight Directory Services Tools"
    (not the "More Windows features" link - RSAT is not listed there)

A reboot may be required before the module appears. Check with:
    Get-WindowsCapability -Online -Name 'Rsat.ActiveDirectory*' | Select-Object Name, State

On a server, run:
    Install-WindowsFeature RSAT-AD-PowerShell

See docs/SETUP.md section 3.
"@
}

Import-Module ActiveDirectory -ErrorAction Stop

$config = Import-OnboardKitConfig -ConfigPath $ConfigPath

# Every AD cmdlet in this script gets these, so an explicit -Server flows
# through consistently.
$adCommon = @{}
if ($Server) {
    $adCommon['Server'] = $Server
}

Write-Host ''
Write-Host '=========================================================' -ForegroundColor White
Write-Host ' MSPOnboardKit - new user provisioning' -ForegroundColor White
Write-Host '=========================================================' -ForegroundColor White
Write-Detail "Config file : $($config.ConfigPath)"
Write-Detail "Domain      : $($config.Domain)"

if ($WhatIfPreference) {
    Write-Host ''
    Write-Host ' DRY RUN (-WhatIf): nothing will be created or changed.' -ForegroundColor Yellow
}

#endregion


#region Look up the mirror user ----------------------------------------------

# Fetched here rather than further down, because where the new account gets
# created depends on where this person lives. Reused later for their groups,
# so Active Directory is only asked once.
$mirror = $null

if ($MirrorUser) {

    Write-Step "Looking up the mirror user"

    try {
        $mirror = Get-ADUser -Identity $MirrorUser -Properties MemberOf, DisplayName, DistinguishedName @adCommon
    }
    catch {
        throw @"
Could not find the mirror user '$MirrorUser'.

Use their logon name (sAMAccountName), not their display name or email
address. For example 'jdoe', not 'John Doe' and not 'jdoe@$($config.Domain)'.

Active Directory reported: $($_.Exception.Message)
"@
    }

    $mirrorLabel = if ($mirror.DisplayName) { "$($mirror.DisplayName) ($MirrorUser)" } else { $MirrorUser }
    Write-Ok "Found: $mirrorLabel"
}

#endregion


#region Decide which OU to create the account in -----------------------------

Write-Step "Working out where to create the account"

# Precedence: an explicit -TargetOU always wins; otherwise follow the mirror
# user; otherwise fall back to the config default.
if ($TargetOU) {
    $ou       = $TargetOU
    $ouReason = 'you passed -TargetOU'
}
elseif ($mirror -and $config.MirrorTargetOU) {

    $mirrorOu = Get-OnboardParentOU -DistinguishedName $mirror.DistinguishedName

    # The guard blocks only the inferred path. Someone who really means to
    # create an account in a protected OU can still say so with -TargetOU.
    if (Test-OnboardProtectedOU -DistinguishedName $mirrorOu -ProtectedOUs $config.ProtectedOUs) {
        throw @"
The mirror user '$MirrorUser' is in an OU that is marked as protected:

    $mirrorOu

Refusing to create a new hire there automatically. Protected OUs usually hold
administrator accounts, service accounts or equipment - putting an ordinary
new starter in one would quietly give them the wrong policies.

If that really is where this account belongs, say so explicitly:

    -TargetOU '$mirrorOu'

Otherwise pick a different mirror user, or pass the correct OU with -TargetOU.
The protected list is ProtectedOUs in $($config.ConfigPath).
"@
    }

    $ou       = $mirrorOu
    $ouReason = "copied from mirror user $MirrorUser"
}
else {
    $ou       = $config.DefaultTargetOU
    $ouReason = 'DefaultTargetOU from your config file'
}

Write-Ok "Target OU: $ou"
Write-Detail "Chosen because: $ouReason"

if ($mirror -and -not $TargetOU -and -not $config.MirrorTargetOU) {
    Write-Detail 'MirrorTargetOU is turned off in your config, so the mirror user'
    Write-Detail 'has been used for groups only, not for placement.'
}

#endregion


#region Validate the target OU exists ----------------------------------------

Write-Step "Checking the target OU exists"

try {
    $null = Get-ADOrganizationalUnit -Identity $ou @adCommon
    Write-Ok "Found: $ou"
}
catch {
    throw @"
The target OU does not exist, or you cannot read it:

    $ou

Check the DefaultTargetOU value in:
    $($config.ConfigPath)

It must be the OU's full distinguished name. docs/SETUP.md section 6 shows
how to copy the exact value out of Active Directory Users and Computers.

Active Directory reported: $($_.Exception.Message)
"@
}

#endregion


#region Work out the alias ---------------------------------------------------

Write-Step "Working out the email alias"

$baseAlias = ConvertTo-OnboardAlias -FirstName $FirstName -LastName $LastName -Template $config.AliasTemplate
Write-Detail "Template '$($config.AliasTemplate)' gives: $baseAlias"

$aliasParams = @{
    BaseAlias = $baseAlias
    Domain    = $config.Domain
}
if ($Server) {
    $aliasParams['Server'] = $Server
}

$alias = Get-UniqueOnboardAlias @aliasParams
$upn   = "$alias@$($config.Domain)"
$sam   = ConvertTo-OnboardSamAccountName -Alias $alias

if ($alias -ne $baseAlias) {
    Write-Warn "'$baseAlias@$($config.Domain)' was already taken."
}
Write-Ok "Email address will be: $upn"

if ($sam -ne $alias) {
    Write-Warn "Logon name shortened to '$sam' (Active Directory allows only 20 characters)."
}
else {
    Write-Detail "Logon name: $sam"
}

#endregion


#region Work out which groups to add -----------------------------------------

Write-Step "Working out group membership"

$targetGroups = New-Object System.Collections.Generic.List[object]

if ($mirror) {

    # Already fetched further up, when working out the target OU.
    Write-Detail "Copying groups from mirror user: $MirrorUser"

    foreach ($groupDn in $mirror.MemberOf) {
        $targetGroups.Add((Get-ADGroup -Identity $groupDn -Properties objectSid @adCommon))
    }

    if ($targetGroups.Count -eq 0) {
        Write-Warn "$MirrorUser is not a member of any groups. The new account will be created with no group membership."
    }
}
else {

    Write-Detail 'No mirror user given, using DefaultGroups from the config file.'

    foreach ($groupName in $config.DefaultGroups) {
        try {
            $targetGroups.Add((Get-ADGroup -Identity $groupName -Properties objectSid @adCommon))
        }
        catch {
            throw @"
The group '$groupName' from DefaultGroups does not exist, or you cannot read it.

Check the DefaultGroups list in:
    $($config.ConfigPath)

Active Directory reported: $($_.Exception.Message)
"@
        }
    }

    if ($targetGroups.Count -eq 0) {
        Write-Warn 'DefaultGroups is empty, so the new account will be created with no group membership.'
        Write-Detail 'That is fine if you intend to add groups manually afterwards.'
    }
}

# The primary group (normally "Domain Users") is granted automatically and
# cannot be added with Add-ADGroupMember. Identified by its RID rather than
# its name so this still works on non-English domains.
$primaryGroups = @($targetGroups | Where-Object { $_.objectSid.Value -match '-513$' })
foreach ($primary in $primaryGroups) {
    Write-Detail "Skipping '$($primary.Name)' - it is the primary group and is granted automatically."
    [void]$targetGroups.Remove($primary)
}

if ($targetGroups.Count -gt 0) {
    Write-Ok "$($targetGroups.Count) group(s) to add:"
    foreach ($group in $targetGroups) {
        Write-Detail "  - $($group.Name)"
    }
}

#endregion


#region Create the account ---------------------------------------------------

Write-Step "Creating the account"

$displayName  = "$FirstName $LastName"
$tempPassword = New-OnboardTempPassword -Length $config.TempPasswordLength

$summary = [ordered]@{
    DisplayName   = $displayName
    Alias         = $alias
    EmailAddress  = $upn
    LogonName     = $sam
    OrganizationalUnit       = $ou
    OrganizationalUnitReason = $ouReason
    TempPassword  = $null
    MirrorUser    = if ($MirrorUser) { $MirrorUser } else { '(none - used DefaultGroups)' }
    GroupsAdded   = @()
    GroupsFailed  = @()
    SyncTriggered = $false
    SyncMessage   = ''
    WhatIf        = [bool]$WhatIfPreference
}

$accountCreated = $false

if ($PSCmdlet.ShouldProcess($upn, "Create Active Directory account in $ou")) {

    $newUserParams = @{
        Name                  = $displayName
        GivenName             = $FirstName
        Surname               = $LastName
        DisplayName           = $displayName
        SamAccountName        = $sam
        UserPrincipalName     = $upn
        EmailAddress          = $upn
        Path                  = $ou
        AccountPassword       = (ConvertTo-SecureString -String $tempPassword -AsPlainText -Force)
        Enabled               = $true
        ChangePasswordAtLogon = $true

        # Uppercase SMTP: marks the primary address. There must be exactly one.
        OtherAttributes       = @{ proxyAddresses = @("SMTP:$upn") }
    }

    try {
        New-ADUser @newUserParams @adCommon
        $accountCreated = $true
        $summary.TempPassword = $tempPassword
        Write-Ok "Created $upn"
    }
    catch {
        throw @"
Could not create the account.

Active Directory reported: $($_.Exception.Message)

Common causes:
  - "Access is denied"  -> your account does not have permission to create
                           users in that OU. See docs/SETUP.md section 2.
  - "already exists"     -> an account named '$displayName' is already in
                           that OU. Check for a duplicate or a leftover
                           test account.
"@
    }
}
else {
    Write-Detail "Would create: $upn"
    Write-Detail "  Display name : $displayName"
    Write-Detail "  Logon name   : $sam"
    Write-Detail "  Location     : $ou"
    Write-Detail "  proxyAddresses: SMTP:$upn"
    Write-Detail '  Enabled, with a random password and "must change at next logon"'
}

#endregion


#region Add groups -----------------------------------------------------------

if ($targetGroups.Count -gt 0) {

    Write-Step "Adding group membership"

    $groupsAdded  = New-Object System.Collections.Generic.List[string]
    $groupsFailed = New-Object System.Collections.Generic.List[object]

    foreach ($group in $targetGroups) {

        # ShouldProcess prints its own "What if:" line during a dry run, so
        # there is nothing to add here.
        if (-not $PSCmdlet.ShouldProcess($group.Name, "Add $upn to group")) {
            continue
        }

        if (-not $accountCreated) {
            continue
        }

        # One group failing must not abandon the rest. Every failure is
        # collected and reported together at the end.
        try {
            Add-ADGroupMember -Identity $group.DistinguishedName -Members $sam @adCommon -ErrorAction Stop
            $groupsAdded.Add($group.Name)
            Write-Ok "Added to $($group.Name)"
        }
        catch {
            $groupsFailed.Add([pscustomobject]@{
                Group  = $group.Name
                Reason = $_.Exception.Message
            })
            Write-Fail "Could not add to $($group.Name): $($_.Exception.Message)"
        }
    }

    # .ToArray(), not @( ): a generic List left in the summary makes the
    # [pscustomobject] cast at the end of the script throw on PS 5.1.
    $summary.GroupsAdded  = $groupsAdded.ToArray()
    $summary.GroupsFailed = $groupsFailed.ToArray()
}

#endregion


#region Trigger directory sync -----------------------------------------------

Write-Step "Triggering directory sync to Microsoft 365"

if ($SkipSync) {
    $summary.SyncMessage = 'Skipped (-SkipSync was used).'
    Write-Detail $summary.SyncMessage
}
elseif (-not $accountCreated) {
    $summary.SyncMessage = 'Skipped (no account was created).'
    Write-Detail $summary.SyncMessage
}
elseif (-not $PSCmdlet.ShouldProcess('Entra Connect', 'Start a delta sync cycle')) {
    $summary.SyncMessage = 'Would trigger a delta sync.'
    Write-Detail $summary.SyncMessage
}
else {

    # A failure here is reported but never fatal: the account is already
    # created correctly at this point, and sync also runs on its own schedule
    # (typically every 30 minutes) regardless.
    try {
        if ($config.AdSyncServer) {
            Write-Detail "Running on remote server: $($config.AdSyncServer)"
            Invoke-Command -ComputerName $config.AdSyncServer -ScriptBlock {
                Import-Module ADSync -ErrorAction Stop
                Start-ADSyncSyncCycle -PolicyType Delta
            } -ErrorAction Stop | Out-Null
        }
        elseif (Get-Command -Name Start-ADSyncSyncCycle -ErrorAction SilentlyContinue) {
            Write-Detail 'Running locally.'
            Start-ADSyncSyncCycle -PolicyType Delta -ErrorAction Stop | Out-Null
        }
        else {
            throw 'Start-ADSyncSyncCycle is not available on this machine.'
        }

        $summary.SyncTriggered = $true
        $summary.SyncMessage   = 'Delta sync started.'
        Write-Ok $summary.SyncMessage
    }
    catch {
        $summary.SyncMessage = "Not triggered: $($_.Exception.Message)"
        Write-Warn $summary.SyncMessage
        Write-Detail 'The account was still created successfully.'
        Write-Detail 'Entra Connect syncs on its own roughly every 30 minutes, so you can'
        Write-Detail 'simply wait, or set AdSyncServer in your config file to trigger it'
        Write-Detail 'remotely next time. See docs/SETUP.md section 11.'
    }
}

#endregion


#region Summary --------------------------------------------------------------

Write-Host ''
Write-Host '=========================================================' -ForegroundColor White
Write-Host ' SUMMARY' -ForegroundColor White
Write-Host '=========================================================' -ForegroundColor White

if ($WhatIfPreference) {
    Write-Host ' This was a DRY RUN. Nothing was created or changed.' -ForegroundColor Yellow
    Write-Host ' Re-run the same command without -WhatIf to do it for real.' -ForegroundColor Yellow
    Write-Host ''
}

Write-Host " Name          : $displayName"
Write-Host " Email address : $upn"
Write-Host " Logon name    : $sam"
Write-Host " Location      : $ou"
Write-Host "                 ($ouReason)" -ForegroundColor DarkGray
Write-Host " Groups from   : $($summary.MirrorUser)"

if ($accountCreated) {
    Write-Host ''
    Write-Host ' Temporary password (shown once - copy it now):' -ForegroundColor Yellow
    Write-Host "     $tempPassword" -ForegroundColor Yellow
    Write-Host ' They will be forced to change it at first sign-in.' -ForegroundColor DarkGray
    Write-Host ' Hand it over in person or by phone, not in the same email as' -ForegroundColor DarkGray
    Write-Host ' their username.' -ForegroundColor DarkGray
}

if ($summary.GroupsAdded.Count -gt 0) {
    Write-Host ''
    Write-Host " Groups added ($($summary.GroupsAdded.Count)):"
    foreach ($name in $summary.GroupsAdded) {
        Write-Host "     - $name" -ForegroundColor Green
    }
}

if ($summary.GroupsFailed.Count -gt 0) {
    Write-Host ''
    Write-Host " GROUPS THAT FAILED ($($summary.GroupsFailed.Count)) - add these by hand:" -ForegroundColor Red
    foreach ($failure in $summary.GroupsFailed) {
        Write-Host "     - $($failure.Group)" -ForegroundColor Red
        Write-Host "       $($failure.Reason)" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host " Directory sync: $($summary.SyncMessage)"

Write-Host ''
Write-Host ' NEXT STEP - assign the Microsoft 365 license' -ForegroundColor Cyan
Write-Host ' Wait for the account to finish syncing to the cloud (usually a few' -ForegroundColor DarkGray
Write-Host ' minutes, up to 30), then run:' -ForegroundColor DarkGray
Write-Host ''
Write-Host "     .\Add-OnboardUserLicense.ps1 -UserPrincipalName $upn" -ForegroundColor White
Write-Host ''
Write-Host ' Add -Wait to have it poll until the account shows up by itself.' -ForegroundColor DarkGray
Write-Host ''

if ($PassThru) {
    [pscustomobject]$summary
}

#endregion
