<#
.SYNOPSIS
    Packages MSPOnboardKit into a zip file you can hand to another administrator.

.DESCRIPTION
    Stages only the files another admin actually needs, then compresses them into
    a versioned zip. Repository plumbing (.git, tests, editor folders) is left out.

    By default your real config.psd1 is EXCLUDED and config.example.psd1 is
    included instead, so the package is safe to produce without thinking about it.
    Bundling your filled-in configuration is a deliberate act - pass -IncludeConfig.

    config.psd1 holds no passwords or secrets by design (see the Graph section of
    config.example.psd1 - client secrets are referenced by environment variable
    name, never stored). It does describe your internal layout: your domain,
    tenant ID, OU distinguished names, and which OUs hold administrator and
    service accounts. Treat a package built with -IncludeConfig as internal to
    your organisation. Do not send it to a client or upload it anywhere public.

.PARAMETER OutputPath
    Folder to write the zip into. Defaults to a 'dist' folder beside this script.

.PARAMETER IncludeConfig
    Include your real config.psd1 so the recipient does not have to configure
    anything. Organisation-internal packages only.

.PARAMETER Force
    Overwrite the zip if one with the same name already exists.

.EXAMPLE
    .\Build-OnboardKitPackage.ps1

    Builds dist\MSPOnboardKit-0.1.0.zip with placeholder config only.

.EXAMPLE
    .\Build-OnboardKitPackage.ps1 -IncludeConfig -Force

    Builds a ready-to-run package for another admin in your organisation,
    overwriting any previous build.

.NOTES
    Recipients must unblock the files after extracting - see docs/SETUP.md
    section 12.
#>

[CmdletBinding()]
param(
    [string] $OutputPath,

    [switch] $IncludeConfig,

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if (-not $OutputPath) { $OutputPath = Join-Path $root 'dist' }

# --- Work out the version from the module manifest ------------------------

$manifestPath = Join-Path $root 'OnboardKit\OnboardKit.psd1'
if (-not (Test-Path $manifestPath)) {
    throw "Cannot find the module manifest at $manifestPath. Run this script from inside the MSPOnboardKit folder."
}

$version = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion
if (-not $version) {
    throw "OnboardKit.psd1 does not declare a ModuleVersion."
}

# --- Decide what goes in --------------------------------------------------

# Everything a recipient needs to run the toolkit. Anything not listed here is
# deliberately left out: .git, tests, .claude, .gitignore, dist.
$items = @(
    'New-OnboardUser.ps1'
    'Add-OnboardUserLicense.ps1'
    'Test-OnboardKitSetup.ps1'
    'OnboardKit'
    'docs'
    'README.md'
    'LICENSE'
)

if ($IncludeConfig) {
    $configPath = Join-Path $root 'config.psd1'
    if (-not (Test-Path $configPath)) {
        throw "-IncludeConfig was given but config.psd1 does not exist yet. Fill it in first (docs/SETUP.md section 6), or build without -IncludeConfig."
    }
    $items += 'config.psd1'
}
else {
    $items += 'config.example.psd1'
}

$missing = @($items | Where-Object { -not (Test-Path (Join-Path $root $_)) })
if ($missing.Count) {
    throw "These expected files are missing from the repository: $($missing -join ', ')"
}

# --- Stage and compress ---------------------------------------------------

$zipName = "MSPOnboardKit-$version.zip"
$zipPath = Join-Path $OutputPath $zipName

if ((Test-Path $zipPath) -and -not $Force) {
    throw "$zipPath already exists. Use -Force to overwrite it."
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
}

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("OnboardKitPkg_" + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $staging "MSPOnboardKit-$version"
New-Item -ItemType Directory -Path $payload | Out-Null

try {
    foreach ($item in $items) {
        Copy-Item -Path (Join-Path $root $item) -Destination $payload -Recurse
    }

    Compress-Archive -Path $payload -DestinationPath $zipPath -Force:$Force
}
finally {
    if (Test-Path $staging) {
        Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Report ---------------------------------------------------------------

$sizeKb = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)

Write-Host ''
Write-Host "Built $zipName ($sizeKb KB)" -ForegroundColor Green
Write-Host "  $zipPath"
Write-Host ''
Write-Host 'Contents:' -ForegroundColor Cyan
$items | ForEach-Object { Write-Host "  $_" }
Write-Host ''

if ($IncludeConfig) {
    Write-Host 'This package contains your real config.psd1.' -ForegroundColor Yellow
    Write-Host 'It describes your domain, tenant ID and OU layout. Keep it inside your' -ForegroundColor Yellow
    Write-Host 'organisation - do not send it to a client or upload it anywhere public.' -ForegroundColor Yellow
}
else {
    Write-Host 'Placeholder config only. The recipient must create their own config.psd1' -ForegroundColor Cyan
    Write-Host 'from config.example.psd1 (docs/SETUP.md section 6).' -ForegroundColor Cyan
}

Write-Host ''
Write-Host 'Tell the recipient to unblock the files after extracting, or PowerShell' -ForegroundColor Cyan
Write-Host 'will refuse to run them:' -ForegroundColor Cyan
Write-Host '    Get-ChildItem -Path . -Recurse | Unblock-File' -ForegroundColor Cyan
Write-Host ''
