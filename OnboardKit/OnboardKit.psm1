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


Export-ModuleMember -Function @(
    'Import-OnboardKitConfig'
    'ConvertTo-OnboardNameToken'
    'ConvertTo-OnboardAlias'
    'ConvertTo-OnboardSamAccountName'
    'Test-OnboardAliasInUse'
    'Get-UniqueOnboardAlias'
    'New-OnboardTempPassword'
)
