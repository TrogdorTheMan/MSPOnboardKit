#Requires -Version 5.1

<#
    MSPOnboardKit - shared helper functions
    Copyright (C) 2026 Cory "TrogdorTheMan" Francis

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
#>

Set-StrictMode -Version Latest

# Repository root: this module lives in <root>\OnboardKit
$script:OnboardKitRoot = Split-Path -Parent $PSScriptRoot

# Longest permitted sAMAccountName in Active Directory.
$script:SamAccountNameMaxLength = 20

# Keys that must be present in config.psd1 for the AD side to work at all.
$script:RequiredConfigKeys = @('Domain', 'AliasTemplate', 'DefaultTargetOU')


function Import-OnboardKitConfig {
    <#
    .SYNOPSIS
        Loads and validates config.psd1.

    .DESCRIPTION
        Reads the configuration with Import-PowerShellDataFile, which parses
        data only and cannot execute code, then checks that every required
        setting is present and fills in defaults for the optional ones.

        Throws a plain-English error naming the exact problem, because the
        person hitting this error is usually setting the toolkit up for the
        first time.

    .PARAMETER ConfigPath
        Explicit path to a config file. When omitted, looks for config.psd1
        in the current directory and then in the repository root.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [string] $ConfigPath
    )

    if ($ConfigPath) {
        $candidates = @($ConfigPath)
    }
    else {
        # Deduplicated: when the working directory is already the repository
        # root, both candidates are the same path.
        $candidates = @(
            (Join-Path -Path (Get-Location).Path -ChildPath 'config.psd1')
            (Join-Path -Path $script:OnboardKitRoot -ChildPath 'config.psd1')
        ) | Select-Object -Unique
    }

    $resolved = $candidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1

    if (-not $resolved) {
        $example = Join-Path -Path $script:OnboardKitRoot -ChildPath 'config.example.psd1'
        throw @"
Could not find a configuration file.

Looked in:
$($candidates | ForEach-Object { "  $_" } | Out-String)
To fix this: copy the example config and fill in your own values.

    Copy-Item '$example' '$(Join-Path $script:OnboardKitRoot 'config.psd1')'

Then open config.psd1 and replace the placeholder values.
See docs/SETUP.md section 6 for what each setting means.
"@
    }

    Write-Verbose "Loading configuration from '$resolved'."

    try {
        $config = Import-PowerShellDataFile -LiteralPath $resolved -ErrorAction Stop
    }
    catch {
        throw @"
The configuration file '$resolved' could not be read.

PowerShell reported: $($_.Exception.Message)

This almost always means a typo in the file. Common causes:
  - A missing closing quote on a value
  - A missing comma between items in an @( ) list
  - A missing closing brace }

Compare your file against config.example.psd1.
"@
    }

    $missing = $script:RequiredConfigKeys | Where-Object { -not $config.ContainsKey($_) -or -not $config[$_] }
    if ($missing) {
        throw @"
The configuration file '$resolved' is missing required setting(s): $($missing -join ', ')

Open the file and make sure each of these has a real value:
$($missing | ForEach-Object { "  $_" } | Out-String)
See docs/SETUP.md section 6 for where to find each value.
"@
    }

    # Fill in optional settings so callers never have to null-check.
    if (-not $config.ContainsKey('DefaultGroups') -or $null -eq $config['DefaultGroups']) {
        $config['DefaultGroups'] = @()
    }
    if (-not $config.ContainsKey('AdSyncServer') -or $null -eq $config['AdSyncServer']) {
        $config['AdSyncServer'] = ''
    }
    if (-not $config.ContainsKey('TempPasswordLength') -or -not $config['TempPasswordLength']) {
        $config['TempPasswordLength'] = 16
    }
    if (-not $config.ContainsKey('Licensing') -or $null -eq $config['Licensing']) {
        $config['Licensing'] = @{ GroupNames = @() }
    }
    if (-not $config['Licensing'].ContainsKey('GroupNames') -or $null -eq $config['Licensing']['GroupNames']) {
        $config['Licensing']['GroupNames'] = @()
    }
    if (-not $config.ContainsKey('Graph') -or $null -eq $config['Graph']) {
        $config['Graph'] = @{}
    }
    foreach ($graphKey in @('AuthMode', 'TenantId', 'ClientId', 'CertificateThumbprint', 'ClientSecretEnvVar')) {
        if (-not $config['Graph'].ContainsKey($graphKey) -or $null -eq $config['Graph'][$graphKey]) {
            $config['Graph'][$graphKey] = ''
        }
    }
    if (-not $config['Graph']['AuthMode']) {
        $config['Graph']['AuthMode'] = 'Delegated'
    }

    # Record where it came from, so scripts can tell the user which file is in play.
    $config['ConfigPath'] = $resolved

    return $config
}


function ConvertTo-OnboardNameToken {
    <#
    .SYNOPSIS
        Reduces a name to lowercase letters and digits only.

    .DESCRIPTION
        Strips accents (Jose -> jose), then removes anything that is not a
        letter or digit (O'Brien -> obrien, Mary-Jane -> maryjane), and
        lowercases the result.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    # Decompose accented characters into base letter + combining mark,
    # then drop the combining marks.
    $decomposed = $Value.Normalize([System.Text.NormalizationForm]::FormD)
    $builder = New-Object System.Text.StringBuilder

    foreach ($char in $decomposed.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }

    $recomposed = $builder.ToString().Normalize([System.Text.NormalizationForm]::FormC)

    return ($recomposed.ToLowerInvariant() -replace '[^a-z0-9]', '')
}


function ConvertTo-OnboardAlias {
    <#
    .SYNOPSIS
        Builds an email alias from a first and last name using a template.

    .DESCRIPTION
        Supported tokens:
            {first}     whole first name
            {last}      whole last name
            {first:N}   first N characters of the first name
            {last:N}    first N characters of the last name

        Anything else in the template is kept literally, so '{first}.{last}'
        produces 'john.smith'.

        An unrecognised token throws rather than silently emitting itself,
        so a typo in the template fails loudly instead of creating a user
        with a broken address.

    .EXAMPLE
        ConvertTo-OnboardAlias -FirstName John -LastName Smith -Template '{first:1}{last}'
        jsmith
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $FirstName,

        [Parameter(Mandatory)]
        [string] $LastName,

        [Parameter(Mandatory)]
        [string] $Template
    )

    $tokens = @{
        first = ConvertTo-OnboardNameToken -Value $FirstName
        last  = ConvertTo-OnboardNameToken -Value $LastName
    }

    if (-not $tokens['first'] -and -not $tokens['last']) {
        throw "Neither '$FirstName' nor '$LastName' contains any letters or digits, so no alias can be built from them."
    }

    $pattern = '\{([A-Za-z]+)(?::(\d+))?\}'

    # Validate the whole template first, so the replacement pass below can
    # never throw from inside a regex callback (which produces a confusing
    # wrapped exception).
    foreach ($match in [regex]::Matches($Template, $pattern)) {
        $name = $match.Groups[1].Value.ToLowerInvariant()

        if (-not $tokens.ContainsKey($name)) {
            throw "Unknown token '$($match.Value)' in alias template '$Template'. The only valid tokens are {first} and {last}, optionally with a length such as {first:1}."
        }

        if ($match.Groups[2].Success -and [int]$match.Groups[2].Value -lt 1) {
            throw "Invalid length in token '$($match.Value)' in alias template '$Template'. The length must be 1 or greater."
        }
    }

    # Built with an explicit loop rather than [regex]::Replace with a
    # ScriptBlock callback: converting a ScriptBlock to a MatchEvaluator runs
    # it in a fresh scope, which makes closing over $tokens unreliable.
    $builder = New-Object System.Text.StringBuilder
    $cursor = 0

    foreach ($match in [regex]::Matches($Template, $pattern)) {

        [void]$builder.Append($Template.Substring($cursor, $match.Index - $cursor))

        $value = $tokens[$match.Groups[1].Value.ToLowerInvariant()]

        if ($match.Groups[2].Success) {
            $length = [int]$match.Groups[2].Value
            if ($length -lt $value.Length) {
                $value = $value.Substring(0, $length)
            }
        }

        [void]$builder.Append($value)
        $cursor = $match.Index + $match.Length
    }

    [void]$builder.Append($Template.Substring($cursor))
    $alias = $builder.ToString()

    if ($alias -match '[{}]') {
        throw "Alias template '$Template' contains an unmatched brace. Tokens must look like {first} or {first:1}."
    }

    if ([string]::IsNullOrWhiteSpace($alias)) {
        throw "Alias template '$Template' produced an empty alias for '$FirstName $LastName'."
    }

    if ($alias.Length -gt 64) {
        throw "Alias '$alias' is $($alias.Length) characters long, which exceeds the 64 character limit for an email address. Use a shorter template, for example '{first:1}{last:20}'."
    }

    if ($alias -notmatch '^[a-z0-9][a-z0-9._-]*$') {
        throw "Alias template '$Template' produced '$alias', which is not a valid email address prefix. Templates may only add dots, hyphens and underscores between tokens."
    }

    return $alias
}


function ConvertTo-OnboardSamAccountName {
    <#
    .SYNOPSIS
        Derives a legal sAMAccountName from an alias.

    .DESCRIPTION
        Active Directory caps sAMAccountName at 20 characters, which is
        shorter than an email alias is allowed to be, so long aliases get
        truncated for the logon name only. The email address keeps its
        full form.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Alias
    )

    if ($Alias.Length -le $script:SamAccountNameMaxLength) {
        return $Alias
    }

    return $Alias.Substring(0, $script:SamAccountNameMaxLength)
}


function Test-OnboardAliasInUse {
    <#
    .SYNOPSIS
        Returns $true if anything in Active Directory already claims this alias.

    .DESCRIPTION
        Checks userPrincipalName, mail, proxyAddresses and sAMAccountName in a
        single LDAP query against all object types - a distribution group
        holding the address counts as a conflict just as much as a user does.

        This is deliberately its own function so the tests can mock it. Mocking
        Get-ADUser directly fails on machines where RSAT is not installed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Alias,

        [Parameter(Mandatory)]
        [string] $Domain,

        [Parameter()]
        [string] $Server
    )

    $upn = "$Alias@$Domain"
    $sam = ConvertTo-OnboardSamAccountName -Alias $Alias

    # Escape the characters that are special inside an LDAP filter.
    $escapedUpn = $upn -replace '([\\\(\)\*])', '\$1'
    $escapedSam = $sam -replace '([\\\(\)\*])', '\$1'

    $ldapFilter = "(|(userPrincipalName=$escapedUpn)(mail=$escapedUpn)(proxyAddresses=smtp:$escapedUpn)(sAMAccountName=$escapedSam))"

    $params = @{
        LDAPFilter  = $ldapFilter
        ErrorAction = 'Stop'
    }
    if ($Server) {
        $params['Server'] = $Server
    }

    $existing = @(Get-ADObject @params)

    return ($existing.Count -gt 0)
}


function Get-UniqueOnboardAlias {
    <#
    .SYNOPSIS
        Finds the first unused variation of an alias.

    .DESCRIPTION
        Tries the base alias first, then appends 2, 3, 4 and so on until an
        unused one is found. Returns the alias that was actually chosen so
        the technician can confirm it before the account is created.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $BaseAlias,

        [Parameter(Mandatory)]
        [string] $Domain,

        [Parameter()]
        [string] $Server,

        [Parameter()]
        [ValidateRange(1, 999)]
        [int] $MaxAttempts = 50
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {

        $candidate = if ($attempt -eq 1) { $BaseAlias } else { "$BaseAlias$attempt" }

        $inUseParams = @{
            Alias  = $candidate
            Domain = $Domain
        }
        if ($Server) {
            $inUseParams['Server'] = $Server
        }

        if (-not (Test-OnboardAliasInUse @inUseParams)) {
            if ($attempt -gt 1) {
                Write-Verbose "Alias '$BaseAlias' was taken; using '$candidate' instead."
            }
            return $candidate
        }

        Write-Verbose "Alias '$candidate' is already in use."
    }

    throw "Could not find an unused alias after $MaxAttempts attempts starting from '$BaseAlias'. Check whether these accounts are stale, or use a different naming template."
}


function Get-OnboardRandomInt {
    <#
    .SYNOPSIS
        Returns a cryptographically random integer in [0, MaxExclusive).

    .DESCRIPTION
        Rejects the tail of the uint32 range that would otherwise skew the
        modulo, so every value is equally likely.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $MaxExclusive,

        [Parameter(Mandatory)]
        [System.Security.Cryptography.RandomNumberGenerator] $Rng
    )

    $bytes = New-Object byte[] 4
    $limit = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$MaxExclusive)

    do {
        $Rng.GetBytes($bytes)
        $value = [BitConverter]::ToUInt32($bytes, 0)
    } while ($value -ge $limit)

    return [int]($value % [uint32]$MaxExclusive)
}


function New-OnboardTempPassword {
    <#
    .SYNOPSIS
        Generates a random temporary password.

    .DESCRIPTION
        Uses the operating system's cryptographic random number generator,
        not Get-Random, which is not safe for secrets.

        Guarantees at least one uppercase letter, one lowercase letter, one
        digit and one symbol so the password satisfies default Active
        Directory complexity rules on the first try.

        Characters that are easily misread aloud or mistyped (0, O, 1, l, I)
        are excluded, because a technician usually reads this to someone.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [ValidateRange(12, 128)]
        [int] $Length = 16
    )

    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'   # no I or O
    $lower   = 'abcdefghijkmnpqrstuvwxyz'   # no l or o
    $digit   = '23456789'                   # no 0 or 1
    $symbol  = '!#%+=?@-_'
    $allSets = @($upper, $lower, $digit, $symbol)
    $every   = ($allSets -join '')

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $chars = New-Object System.Collections.Generic.List[char]

        # One from each set, guaranteeing complexity.
        foreach ($set in $allSets) {
            $chars.Add($set[(Get-OnboardRandomInt -MaxExclusive $set.Length -Rng $rng)])
        }

        # Fill the remainder from the combined pool.
        for ($i = $chars.Count; $i -lt $Length; $i++) {
            $chars.Add($every[(Get-OnboardRandomInt -MaxExclusive $every.Length -Rng $rng)])
        }

        # Fisher-Yates shuffle so the guaranteed characters are not always
        # in the same positions.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = Get-OnboardRandomInt -MaxExclusive ($i + 1) -Rng $rng
            $swap = $chars[$i]
            $chars[$i] = $chars[$j]
            $chars[$j] = $swap
        }

        return (-join $chars)
    }
    finally {
        $rng.Dispose()
    }
}


function Get-OnboardObjectProperty {
    <#
    .SYNOPSIS
        Reads a property that may not be present, without tripping StrictMode.

    .DESCRIPTION
        This module runs under Set-StrictMode -Version Latest, where reading a
        property an object does not have is an error rather than $null. Graph
        objects vary depending on which properties were selected, so every
        read of them has to go through here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]

    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}


function Get-OnboardObjectArrayProperty {
    <#
    .SYNOPSIS
        Reads a possibly-absent property as an array, treating null as empty.

    .DESCRIPTION
        Exists because @($null) in PowerShell is an array of length one
        containing $null, not an empty array - so a plain @() wrapper around a
        missing property would report Count = 1 and quietly break every
        emptiness check built on it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $value = Get-OnboardObjectProperty -InputObject $InputObject -Name $Name

    # The leading comma matters. 'return @()' unrolls to nothing, so the caller
    # gets $null and any .Count on it throws under StrictMode; 'return @($x)'
    # for a single item unrolls to the bare item. Wrapping in an outer array
    # means the unrolling hands back the real array.
    if ($null -eq $value) {
        return ,@()
    }

    return ,@($value)
}


function Test-OnboardLicensingGroup {
    <#
    .SYNOPSIS
        Checks whether a licensing group can actually be used to license someone.

    .DESCRIPTION
        Takes a group object already fetched from Microsoft Graph and reports
        whether members can be added to it, and whether doing so would grant a
        licence. Catching this up front matters because the underlying failure
        is a bare HTTP 403 or a message about objects "originated within an
        external service", neither of which explains anything to the person
        reading it.

        Deliberately makes no Graph calls of its own. That keeps this module
        free of any dependency on the Microsoft.Graph modules, and lets the
        tests cover every branch with fabricated objects and no tenant.

        The caller must have selected these properties, since assignedLicenses
        is not returned by default:

            id, displayName, onPremisesSyncEnabled, groupTypes,
            securityEnabled, mailEnabled, assignedLicenses

    .PARAMETER Group
        A group object from Get-MgGroup.

    .OUTPUTS
        An object with IsUsable, Problems and Warnings. Problems block the add;
        Warnings do not. Each carries Code, Message and Fix.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Group
    )

    $problems = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[object]

    $displayName = Get-OnboardObjectProperty -InputObject $Group -Name 'DisplayName'
    if (-not $displayName) {
        $displayName = '(unnamed group)'
    }

    $syncEnabled      = Get-OnboardObjectProperty      -InputObject $Group -Name 'OnPremisesSyncEnabled'
    $securityEnabled  = Get-OnboardObjectProperty      -InputObject $Group -Name 'SecurityEnabled'
    $mailEnabled      = Get-OnboardObjectProperty      -InputObject $Group -Name 'MailEnabled'
    $groupTypes       = Get-OnboardObjectArrayProperty -InputObject $Group -Name 'GroupTypes'
    $assignedLicenses = Get-OnboardObjectArrayProperty -InputObject $Group -Name 'AssignedLicenses'

    $isUnified = $groupTypes -contains 'Unified'

    # Compared against $true explicitly: Graph reports null for a group that
    # has never synced, false for one that used to. Only true means "synced
    # right now, and therefore read-only in the cloud".
    if ($syncEnabled -eq $true) {
        $problems.Add([pscustomobject]@{
            Code    = 'SyncedFromOnPrem'
            Message = "'$displayName' is synchronised up from your on-premises Active Directory, so its membership cannot be changed from the cloud."
            Fix     = @"
Microsoft 365 does not allow membership changes to groups that came from your
local Active Directory - they have to be changed in Active Directory instead.

Create a NEW group directly in Entra ID:
    https://entra.microsoft.com  >  Groups  >  New group
Attach the licence to that new group, then put its name in Licensing.GroupNames
in your config file.

See docs/SETUP.md section 5.
"@
        })
    }

    if ($groupTypes -contains 'DynamicMembership') {
        $problems.Add([pscustomobject]@{
            Code    = 'DynamicMembership'
            Message = "'$displayName' uses dynamic membership, so who belongs to it is decided by a rule and members cannot be added by hand."
            Fix     = @"
Either change the group's membership type to 'Assigned' in Entra ID, or leave
the rule in place and let it pick up new hires automatically - in which case
you do not need this script to assign the licence at all.
"@
        })
    }

    # Only flagged when securityEnabled is definitively false. If the property
    # was not selected it reads as null, and guessing from that would block a
    # perfectly good group.
    if ($securityEnabled -eq $false -and -not $isUnified) {
        $groupKind = if ($mailEnabled -eq $true) { 'a distribution group' } else { 'not a security group' }
        $problems.Add([pscustomobject]@{
            Code    = 'NotMemberManageable'
            Message = "'$displayName' is $groupKind. Microsoft 365 only allows members to be added to security groups and Microsoft 365 groups."
            Fix     = @"
Create a security group in Entra ID and attach the licence to that one instead:
    https://entra.microsoft.com  >  Groups  >  New group  >  Group type: Security

See docs/SETUP.md section 5.
"@
        })
    }

    # A warning rather than a problem: the add genuinely succeeds here. If this
    # property could not be read for a permissions reason, treating it as fatal
    # would block a real onboarding over a false alarm.
    if ($assignedLicenses.Count -eq 0) {
        $warnings.Add([pscustomobject]@{
            Code    = 'NoLicensesAssigned'
            Message = "'$displayName' does not appear to have any licences attached, so joining it may not give anyone a licence."
            Fix     = @"
An administrator needs to attach the licence to the group:
    https://entra.microsoft.com  >  Billing  >  Licenses  >  All products
    tick the licence  >  Assign  >  choose this group

If you know the licence is already attached, this may just mean your account
cannot read that setting, and you can ignore it.

See docs/SETUP.md section 5.
"@
        })
    }

    # .ToArray() rather than @( ): casting a hashtable to [pscustomobject]
    # throws "Argument types do not match" in Windows PowerShell 5.1 if any
    # value is a generic List, and @( ) does not convert it.
    return [pscustomobject]@{
        GroupName = $displayName
        IsUsable  = ($problems.Count -eq 0)
        Problems  = $problems.ToArray()
        Warnings  = $warnings.ToArray()
    }
}


Export-ModuleMember -Function @(
    'Import-OnboardKitConfig'
    'ConvertTo-OnboardNameToken'
    'ConvertTo-OnboardAlias'
    'ConvertTo-OnboardSamAccountName'
    'Test-OnboardAliasInUse'
    'Get-UniqueOnboardAlias'
    'New-OnboardTempPassword'
    'Test-OnboardLicensingGroup'
)
