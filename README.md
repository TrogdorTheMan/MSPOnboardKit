# MSPOnboardKit

Open source toolkit for automating new-user onboarding across client environments. Creates the
Active Directory account, generates the email alias, mirrors group membership, triggers a
directory sync, and assigns Microsoft 365 licensing — all driven by a config file, so the same
tool can be pointed at any tenant or domain without touching the scripts.

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
| **Step 1** | `New-OnboardUser.ps1` | AD account, email alias with collision handling, `proxyAddresses`, group mirroring, directory sync |
| **Step 2** | `Add-OnboardUserLicense.ps1` | Microsoft 365 license, via Entra ID group-based licensing |
| **Check** | `Test-OnboardKitSetup.ps1` | Read-only preflight that validates your whole setup |

Two steps, because a new account has to finish syncing from Active Directory up to Entra ID
before it can be licensed.

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
config instead.

## 📘 Full setup guide

**New to this? Start here → [docs/SETUP.md](docs/SETUP.md)**

A step-by-step walkthrough written for someone who has never set up a PowerShell tool before.
It covers installing prerequisites, the permissions you need (and how to ask for them),
filling in every config value and where to find it, a troubleshooting section, and a glossary.

## Configuration

Everything environment-specific lives in `config.psd1` — domain, naming convention, target OU,
group names, tenant ID. Nothing is hardcoded in the scripts.

`config.psd1` is gitignored. Only `config.example.psd1`, which contains placeholders and inline
documentation for every setting, is committed. **Never put real values in the example file.**

Secrets are never stored in config. Certificate-based auth is preferred, and if a client secret
must be used, the config holds only the *name* of an environment variable containing it.

## Tests

```powershell
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck   # Pester 5 or newer
Invoke-Pester .\tests
```

50 tests, all passing. They need no Active Directory and no Microsoft 365 tenant — the one function that talks to
AD is mocked. They cover alias generation, collision handling, name normalisation, password
complexity, and config validation.

## Roadmap

Phase 1 (this release) covers AD provisioning and licensing. Planned next:

- **Structured intake** — replacing freeform email requests with a validated form or ticket
  type, keeping a human approval step before any account is created
- **Dialpad provisioning** — via REST API v2 / SCIM

## License

Licensed under the **GNU Affero General Public License v3.0** — see [LICENSE](LICENSE).

Copyright © 2026 Cory "TrogdorTheMan" Francis

> **Note on AGPL §13:** if you modify this software and make it available to others over a
> network, you must also make your modified source available to those users. For normal use —
> running it internally to onboard your own staff — this imposes no obligation on you.
