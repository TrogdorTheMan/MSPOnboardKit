# MSPOnboardKit

Open source toolkit for automating new-user onboarding across client environments. Creates the
Active Directory account, generates the email alias, mirrors an existing user's group membership
and OU placement, triggers a directory sync, and assigns Microsoft 365 licensing — all driven by
a config file, so the same tool can be pointed at any tenant or domain without touching the
scripts.

Written to be run by a technician who is not an Active Directory specialist: it explains what it
is about to do, and when something is wrong it says which thing and how to fix it.

> ### ⚠️ Read this first
>
> **These scripts create and modify real Active Directory accounts and real Microsoft 365
> objects.** They are not a simulation.
>
> Review the code before running it against your own environment, and always do a dry run
> first:
>
> ```powershell
> .\New-OnboardUser.ps1 -FirstName Test -LastName User -WhatIf
> ```
>
> `-WhatIf` shows you exactly what would happen and changes nothing.

---

## What it does

| | Script | What it handles |
|---|---|---|
| **Step 1** | `New-OnboardUser.ps1` | AD account, email alias with collision handling, `proxyAddresses`, group **and OU** mirroring, directory sync |
| **Step 2** | `Add-OnboardUserLicense.ps1` | Microsoft 365 license, via Entra ID group-based licensing |
| **Check** | `Test-OnboardKitSetup.ps1` | Read-only preflight that validates your whole setup |

Two steps, because a new account has to finish syncing from Active Directory up to Entra ID
before it can be licensed.

Both steps support `-WhatIf`, report every failure rather than stopping at the first, and print
a summary you can hand to whoever asked for the account.

### Mirroring copies placement, not just membership

Where OUs carry Group Policy — a `USB-Restrict` OU, an `SSL VPN Access` OU — an account's
placement *is* part of its configuration. So `-MirrorUser` creates the new hire in the **same
OU** as the person being mirrored, not in the default one. Copying someone's groups while
leaving them elsewhere would grant the access without the restrictions, and nothing would look
wrong.

`ProtectedOUs` stops that being abused: if the mirror user turns out to live in an admin or
service-account OU, the script refuses rather than quietly placing a new starter there.
`-TargetOU` always overrides both.

### The licensing group is validated before it is used

Group-based licensing fails in ways that produce an unhelpful HTTP 403. Before adding anyone,
the toolkit checks the group is not synced from on-premises AD (which makes it read-only in the
cloud), does not use dynamic membership, is not a distribution group, and actually has a licence
attached — and explains which of those is wrong.

## Requirements

- **Windows PowerShell 5.1+** and the `ActiveDirectory` module (RSAT) — for step 1
- **PowerShell 7 recommended** and the `Microsoft.Graph` modules — for step 2
- Entra ID licensing group(s) that already carry the license SKUs (a one-time admin task)

## Quick start

```powershell
# 1. Create your config from the example and fill it in
Copy-Item .\config.example.psd1 .\config.psd1
notepad .\config.psd1

# 2. Check everything is set up correctly (read-only, changes nothing)
.\Test-OnboardKitSetup.ps1

# 3. Dry run
.\New-OnboardUser.ps1 -FirstName John -LastName Smith -MirrorUser jdoe -WhatIf

# 4. For real
.\New-OnboardUser.ps1 -FirstName John -LastName Smith -MirrorUser jdoe

# 5. Once the account has synced to the cloud
.\Add-OnboardUserLicense.ps1 -UserPrincipalName jsmith@contoso.com -Wait
```

`-MirrorUser` is optional. Leave it out and the new hire gets the `DefaultGroups` from your
config, created in `DefaultTargetOU`.

## 📘 Full setup guide

**New to this? Start here → [docs/SETUP.md](docs/SETUP.md)**

A step-by-step walkthrough written for someone who has never set up a PowerShell tool before.
It covers installing prerequisites, the permissions you need (and how to ask for them),
filling in every config value and where to find it, a troubleshooting section, and a glossary.

## Configuration

Everything environment-specific lives in `config.psd1`. Nothing is hardcoded in the scripts.

| Setting | Controls |
|---|---|
| `Domain` | Email domain used for the alias, UPN and `proxyAddresses` |
| `AliasTemplate` | Naming convention as a token template — `'{first:1}{last}'` → `jsmith` |
| `DefaultTargetOU` | Where accounts are created when no mirror user is given |
| `DefaultGroups` | Baseline groups when no mirror user is given |
| `MirrorTargetOU` | Whether mirroring also copies OU placement (default `$true`) |
| `ProtectedOUs` | OUs that auto-placement must never choose |
| `AdSyncServer` | Entra Connect host, if the sync must be triggered remotely |
| `TempPasswordLength` | Length of the generated temporary password |
| `Licensing.GroupNames` | Entra ID groups that carry the license SKUs |
| `Graph.*` | Tenant ID and how the licensing step authenticates |

It's a `.psd1` rather than JSON so every setting can be documented inline, right where it gets
edited. `Import-PowerShellDataFile` parses data only and cannot execute code.

`config.psd1` is gitignored. Only `config.example.psd1`, which contains placeholders and inline
documentation for every setting, is committed. **Never put real values in the example file.**

Secrets are never stored in config. Certificate-based auth is preferred, and if a client secret
must be used, the config holds only the *name* of an environment variable containing it.

## Tests

```powershell
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck   # Pester 5 or newer
Invoke-Pester .\tests
```

**81 tests, all passing.** They need no Active Directory and no Microsoft 365 tenant: the logic
lives in pure functions in the `OnboardKit` module, and the single function that queries AD is
isolated specifically so it can be mocked.

Covered: alias generation and collision handling · name normalisation (accents, apostrophes,
hyphens) · `sAMAccountName` truncation · password length, complexity and uniqueness · config
loading, defaults and validation · distinguished-name parsing, including escaped commas ·
protected-OU matching · licensing-group validation.

Several of those exist because the case is a silent-wrong-answer bug rather than a crash — a
user named `Smith, John` whose DN contains an escaped comma, or an `OU=Admin` entry that a
naive string match would treat as covering `OU=Administration`.

> The test file is stored **UTF-8 with BOM** and must stay that way. It contains accented names
> as test data, and Windows PowerShell 5.1 assumes ANSI for files without a BOM — which corrupts
> them and produces failures that look like bugs in the code.

## Status

Phase 1 — AD provisioning and Microsoft 365 licensing — is complete and unit-tested. It has not
yet been exercised against a production domain, so treat the first run against yours as a pilot
and use `-WhatIf` liberally.

Planned next:

- **Structured intake** — replacing freeform email requests with a validated form or ticket
  type, keeping a human approval step before any account is created
- **Dialpad provisioning** — via REST API v2 / SCIM

## License

Licensed under the **GNU Affero General Public License v3.0** — see [LICENSE](LICENSE).

Copyright © 2026 Cory "TrogdorTheMan" Francis

> **Note on AGPL §13:** if you modify this software and make it available to others over a
> network, you must also make your modified source available to those users. For normal use —
> running it internally to onboard your own staff — this imposes no obligation on you.
