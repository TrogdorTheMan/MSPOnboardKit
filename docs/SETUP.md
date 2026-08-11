# MSPOnboardKit — Setup Guide

This guide is written for someone who has **never set up a PowerShell tool before**. It does
not assume you know what Active Directory, Entra ID, or an OU is — those are explained in the
[Glossary](#12-glossary) at the bottom.

Work through the sections in order. Do not skip ahead.

> **Realistic expectation:** you will probably not have permission to do all of this yourself.
> That is normal and expected. [Section 2](#2-permissions-you-need-before-you-start) tells you
> exactly what to ask for and gives you wording you can copy and paste to whoever administers
> your systems.

**Contents**

1. [What this does and what it does not do](#1-what-this-does-and-what-it-does-not-do)
2. [Permissions you need before you start](#2-permissions-you-need-before-you-start)
3. [Install the prerequisites](#3-install-the-prerequisites)
4. [Get the code](#4-get-the-code)
5. [One-time Microsoft 365 setup](#5-one-time-microsoft-365-setup)
6. [Fill in your config file](#6-fill-in-your-config-file)
7. [Run the setup check](#7-run-the-setup-check)
8. [Your first run — a safe dry run](#8-your-first-run--a-safe-dry-run)
9. [Creating a real account](#9-creating-a-real-account)
10. [Assigning the Microsoft 365 license](#10-assigning-the-microsoft-365-license)
11. [Troubleshooting](#11-troubleshooting)
12. [Glossary](#12-glossary)

---

## 1. What this does and what it does not do

When a new person joins the company, someone normally has to do all of this by hand:

- Create their user account
- Invent an email address for them and check nobody already has it
- Set a hidden field called `proxyAddresses` so email works properly
- Look at an existing employee and copy every group they are in
- Push those changes up to Microsoft 365
- Give them a Microsoft 365 license

This toolkit does all of that with two commands.

**It does this:**

| Step | Script | What happens |
|---|---|---|
| 1 | `New-OnboardUser.ps1` | Creates the account, sets the email address, copies groups, pushes to Microsoft 365 |
| 2 | `Add-OnboardUserLicense.ps1` | Gives them their Microsoft 365 license |

They are two separate commands on purpose. After step 1, the account has to travel from your
local server up to Microsoft 365, which takes a few minutes. Step 2 cannot run until it
arrives.

**It does NOT do this:**

- It does not create the license groups in Microsoft 365 — that is a one-off job for an
  administrator, see [section 5](#5-one-time-microsoft-365-setup)
- It does not set up phones, or any application other than Microsoft 365
- It does not decide *who* should be created — a human still does that

---

## 2. Permissions you need before you start

Creating user accounts is a privileged action. Most helpdesk accounts cannot do it by default.

Here is exactly what is needed. Check them off, and for any you do not have, use the email
template below.

| # | Permission | What it is for | How to tell if you have it |
|---|---|---|---|
| 1 | Create user accounts in your target OU | Making the account | The setup check in [section 7](#7-run-the-setup-check) tests this |
| 2 | Modify group membership in Active Directory | Copying the mirror user's groups | Same |
| 3 | Run a directory sync | Pushing changes to Microsoft 365 | Same |
| 4 | Manage group membership in Entra ID | Assigning the license | The setup check with `-IncludeCloud` tests this |

Permissions 1–3 are on your local network. Permission 4 is in Microsoft 365. They are granted
by different people in some companies.

### Email template — copy, fill in, and send

> **Subject:** Access request — automating new-hire account setup
>
> Hi,
>
> I am setting up a tool that automates creating new-hire accounts, so that account creation
> is consistent and does not depend on someone copying settings by hand.
>
> To use it, my account (`YOUR-USERNAME-HERE`) needs:
>
> 1. Permission to **create user objects** in this OU:
>    `PASTE-THE-OU-HERE` (see section 6 of the setup guide for how to find this)
> 2. Permission to **modify membership of the groups** new hires get added to
> 3. Permission to **trigger a delta directory sync** on the Entra Connect server,
>    or confirmation of which server that is so it can be triggered remotely
> 4. The **Groups Administrator** role in Entra ID, or membership of a group that can
>    manage membership of our licensing groups
>
> I would also like to confirm that our license-assignment groups exist in Entra ID and
> already have the correct license SKUs attached — the tool adds new hires to those groups
> rather than assigning licenses one at a time.
>
> Happy to walk through what the tool does first if that is useful. It supports a dry-run
> mode, so I can demonstrate exactly what it would do without changing anything.
>
> Thanks,

**If you are told no:** that is a legitimate answer. You can still be the person who runs the
dry run (`-WhatIf`) and hands the output to someone who does have the rights. The dry run
needs only read access.

---

## 3. Install the prerequisites

Everything here is free and made by Microsoft.

### 3.1 Check your PowerShell version

Open PowerShell and run:

```powershell
$PSVersionTable
```

Look at the line that says `PSVersion`. You need **5.1 or higher**. Windows 10 and 11 come
with 5.1, so this almost always passes.

### 3.2 Install the Active Directory tools (RSAT)

This is what lets PowerShell talk to Active Directory.

**On Windows 10 or 11:**

Right-click the Start button, choose **Terminal (Admin)** or **Windows PowerShell (Admin)**,
then run:

```powershell
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
```

If you prefer clicking: **Settings → System → Optional features → Add an optional feature**,
search for `RSAT: Active Directory`, and install
*RSAT: Active Directory Domain Services and Lightweight Directory Services Tools*.

**On a Windows Server:**

```powershell
Install-WindowsFeature RSAT-AD-PowerShell
```

**Check it worked** — close and reopen PowerShell, then run:

```powershell
Get-Module -ListAvailable ActiveDirectory
```

You should see a line mentioning `ActiveDirectory`. If you see nothing, it did not install.

### 3.3 Install PowerShell 7

The licensing part works better in PowerShell 7. It installs alongside your existing
PowerShell rather than replacing it.

```powershell
winget install --id Microsoft.PowerShell --source winget
```

If `winget` is not recognised, download it instead from
<https://github.com/PowerShell/PowerShell/releases> and pick the file ending in `-win-x64.msi`.

After installing, you will have a new Start menu entry called **PowerShell 7**. Use that one
for the licensing script.

### 3.4 Install the Microsoft 365 tools

Open PowerShell (it does **not** need to be Admin for this) and run:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

If it asks about an *untrusted repository*, type `Y` and press Enter. This is a large download
and can take **five minutes or more**. Let it finish.

### 3.5 Allow scripts to run

> **This is the single most common thing that stops these scripts working.** Windows blocks
> PowerShell scripts by default.

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Type `Y` and press Enter. You only ever have to do this once.

---

## 4. Get the code

### Option A — download the ZIP (easiest)

1. Go to the project page on GitHub
2. Click the green **Code** button, then **Download ZIP**
3. Right-click the downloaded ZIP → **Extract All** → put it somewhere sensible like
   `C:\Tools\MSPOnboardKit`

> **Important:** Windows marks files downloaded from the internet as blocked, and blocked
> scripts will refuse to run. Unblock them:
>
> ```powershell
> Get-ChildItem -Path 'C:\Tools\MSPOnboardKit' -Recurse | Unblock-File
> ```

### Option B — use git

```powershell
git clone https://github.com/TrogdorTheMan/MSPOnboardKit.git C:\Tools\MSPOnboardKit
```

### Then move into the folder

Every command in the rest of this guide assumes you are in that folder:

```powershell
cd C:\Tools\MSPOnboardKit
```

---

## 5. One-time Microsoft 365 setup

**This section needs a Microsoft 365 administrator.** If that is not you, forward this section
to them. It only ever has to be done once.

This toolkit uses **group-based licensing**. Instead of assigning a license to each person one
at a time, you create a group, attach the license to the group, and anyone added to that group
automatically receives it.

> ### ⚠️ Create this group in Entra ID — **not** in Active Directory
>
> This is the single easiest mistake to make here, and it is worth understanding before you
> start.
>
> Every other group at your company probably lives in Active Directory, so making this one in
> **Active Directory Users and Computers** feels natural. It does not work. Groups that sync up
> from your local Active Directory are **read-only in Microsoft 365** — the cloud will not let
> anything change their membership, because your local AD is treated as the source of truth.
>
> If you create the licensing group that way, everything looks fine until the licensing step
> runs, and then it fails on every single new hire.
>
> The group must be created at <https://entra.microsoft.com>, as described below. It also must
> be a **Security** (or Microsoft 365) group with **Assigned** membership — a distribution
> group cannot take members this way, and a dynamic group decides its own membership by rule.
>
> `Test-OnboardKitSetup.ps1 -IncludeCloud` checks all of this for you and will say plainly if
> the group is wrong.

### Create the licensing group

1. Go to <https://entra.microsoft.com> and sign in as an administrator
2. In the left menu choose **Groups → All groups → New group**
3. Fill it in:
   - **Group type:** Security
   - **Group name:** something obvious like `LIC-M365-E3`
   - **Membership type:** Assigned
4. Click **Create**

### Attach the license to the group

1. Still in <https://entra.microsoft.com>, go to **Billing → Licenses → All products**
2. Tick the license you want (for example *Microsoft 365 E3*)
3. Click **Assign**
4. Under **Users and groups**, pick the group you just created
5. Review the service plans, then click **Assign**

### Check it worked

Go back to **Groups**, open your group, and choose **Licenses** in the left menu. You should
see the license listed.

Repeat for each different license type you hand out (for example a separate group for
E3 + Security).

**Write down the exact group names.** You will type them into your config file in the next
section, and they must match *exactly*, including capitalisation.

---

## 6. Fill in your config file

This is where you tell the toolkit about your own organisation. Nothing about your company is
built into the scripts — it all lives in this one file.

### Make your copy

```powershell
Copy-Item .\config.example.psd1 .\config.psd1
```

Then open `config.psd1` in Notepad, or any text editor:

```powershell
notepad .\config.psd1
```

> `config.psd1` is deliberately excluded from git, so your real values can never be
> accidentally published. Never put real values into `config.example.psd1`.

### What each setting means, and where to find it

| Setting | What to put | Where to find it |
|---|---|---|
| `Domain` | Your email domain | The part after the `@` in your staff email addresses. If people are `jane@contoso.com`, put `contoso.com` |
| `AliasTemplate` | Your email naming pattern | See the table below |
| `DefaultTargetOU` | Where new accounts get created | See "Finding your OU" below — you must copy this exactly |
| `DefaultGroups` | Baseline groups for new hires | The groups everyone gets. Only used when you do not name a mirror user |
| `AdSyncServer` | Your Entra Connect server | Leave empty if you run the script on that server. Not sure? Leave it empty — the setup check will tell you |
| `TempPasswordLength` | How long the temporary password is | Leave at `16` unless you have a policy that says otherwise |
| `Licensing.GroupNames` | Your license groups | The group names from [section 5](#5-one-time-microsoft-365-setup) |
| `Graph.AuthMode` | How to sign in to Microsoft 365 | Leave as `'Delegated'` — that means "ask me to log in" |
| `Graph.TenantId` | Your Microsoft 365 tenant ID | See "Finding your tenant ID" below |

### Choosing your alias template

Work out what your existing staff email addresses look like, then pick the matching row.
Examples are for a new hire named **John Smith**:

| Your emails look like | Use this template | Result |
|---|---|---|
| `jsmith@…` | `'{first:1}{last}'` | `jsmith` |
| `john.smith@…` | `'{first}.{last}'` | `john.smith` |
| `johnsmith@…` | `'{first}{last}'` | `johnsmith` |
| `johns@…` | `'{first}{last:1}'` | `johns` |
| `john_smith@…` | `'{first}_{last}'` | `john_smith` |

The number after the colon means "only this many letters". So `{first:1}` is the first letter
of the first name, and `{last:7}` is the first seven letters of the last name.

Accents and punctuation are removed for you — `O'Brien` becomes `obrien`, and `José` becomes
`jose`.

### Finding your OU (the `DefaultTargetOU` value)

An OU is just a folder in Active Directory. The toolkit needs its full technical name, which
looks something like `OU=Users,OU=Company,DC=contoso,DC=com`. **You cannot guess this** — one
wrong character and it will not work. Copy it:

1. Open **Active Directory Users and Computers** (press Start and type `dsa.msc`)
2. In the menu bar click **View**, and make sure **Advanced Features** is ticked
   *(this is off by default and the next step will not appear without it)*
3. Find the folder where your normal staff accounts live
4. Right-click that folder → **Properties**
5. Click the **Attribute Editor** tab
6. Scroll down to **distinguishedName**
7. Double-click it, select the whole value, and copy it
8. Paste it into `config.psd1` between the single quotes

**Easier alternative** — if you know roughly what the folder is called, run this and copy the
result:

```powershell
Get-ADOrganizationalUnit -Filter "Name -like '*Users*'" | Select-Object Name, DistinguishedName
```

### Finding your tenant ID

1. Go to <https://entra.microsoft.com>
2. On the **Overview** page, look for **Tenant ID**
3. Click the copy icon next to it

It looks like `a1b2c3d4-5678-90ab-cdef-1234567890ab`.

---

## 7. Run the setup check

Before creating anything for real, check your setup. This command **only reads** — it cannot
create, change, or delete anything.

```powershell
.\Test-OnboardKitSetup.ps1
```

You will get a list like this:

```
--- Your computer ---
[ PASS ] PowerShell version - 5.1.26100.8875 (fine for creating users)
[ PASS ] Execution policy - RemoteSigned

--- Required software ---
[ PASS ] ActiveDirectory module - Installed.
[ PASS ] Microsoft Graph modules - Installed.

--- Your configuration file ---
[ PASS ] config.psd1 - Loaded from C:\Tools\MSPOnboardKit\config.psd1
[ PASS ] AliasTemplate - '{first:1}{last}' - a new hire named John Smith would get jsmith@contoso.com

--- Active Directory ---
[ PASS ] Domain reachable - contoso.com
[ PASS ] DefaultTargetOU - OU=Users,OU=Company,DC=contoso,DC=com
[ PASS ] Group 'All Staff' - Exists.
[ PASS ] Directory sync - Entra Connect is installed on this machine.
```

**Read the `AliasTemplate` line carefully.** It shows the email address a new hire named John
Smith would actually receive. If that does not match how your company's email addresses look,
fix your template before going any further.

Anything marked `[ FAIL ]` has instructions printed directly underneath it in yellow. Fix
those and run it again until nothing fails.

When you are ready to check the Microsoft 365 side too — this opens a sign-in window:

```powershell
.\Test-OnboardKitSetup.ps1 -IncludeCloud
```

---

## 8. Your first run — a safe dry run

`-WhatIf` means **"tell me what you would do, but do not actually do it."** Nothing is created.
It is completely safe, and you should use it every time you try something new.

```powershell
.\New-OnboardUser.ps1 -FirstName Test -LastName User -MirrorUser jdoe -WhatIf
```

Replace `jdoe` with the username of a real existing employee whose groups the new person should
have. Use their **username**, not their full name — `jdoe`, not `John Doe`.

You will see something like this:

```
 DRY RUN (-WhatIf): nothing will be created or changed.

==> Checking the target OU exists
    [ ok ] Found: OU=Users,OU=Company,DC=contoso,DC=com

==> Working out the email alias
           Template '{first:1}{last}' gives: tuser
    [ ok ] Email address will be: tuser@contoso.com
           Logon name: tuser

==> Working out group membership
           Copying groups from mirror user: jdoe
           Found: John Doe (jdoe)
    [ ok ] 3 group(s) to add:
             - All Staff
             - Accounting
             - VPN Users
```

**What to check before going further:**

1. **The email address** is in your company's normal format
2. **The group list** matches what the mirror user actually has — open the mirror user in
   Active Directory Users and Computers, look at their **Member Of** tab, and compare
3. **The OU** is where staff accounts really belong

If any of that is wrong, fix your config file and run the dry run again. Nothing has been
created, so there is nothing to undo.

---

## 9. Creating a real account

Once the dry run looks right, run the **same command without `-WhatIf`**:

```powershell
.\New-OnboardUser.ps1 -FirstName John -LastName Smith -MirrorUser jdoe
```

It will ask you to confirm before creating anything. Type `Y` and press Enter.

### If there is no mirror user

Sometimes there is nobody suitable to copy. Leave `-MirrorUser` out entirely:

```powershell
.\New-OnboardUser.ps1 -FirstName John -LastName Smith
```

The new hire then gets whatever is listed in `DefaultGroups` in your config file. If that list
is empty, they are created with no groups and you can add them by hand afterwards.

### The temporary password

At the end you will see:

```
 Temporary password (shown once - copy it now):
     f5Dm3px4n_3f#QKW
```

**Copy it now.** It is not saved anywhere and cannot be shown again. If you lose it, reset the
password in Active Directory Users and Computers.

The new hire is forced to change it the first time they sign in.

> **Hand it over safely.** Do not email the username and the password together in one message.
> Give the password in person, by phone, or by text — separately from the username.

### If some groups failed

The script never gives up halfway. If it cannot add one group, it carries on with the rest and
lists the failures at the end in red:

```
 GROUPS THAT FAILED (1) - add these by hand:
     - Finance Admins
       Insufficient access rights to perform the operation
```

That message means your account is not allowed to modify that particular group. Add the person
to it manually, or ask an administrator. Everything else worked.

---

## 10. Assigning the Microsoft 365 license

The account now exists locally, but Microsoft 365 does not know about it yet. It has to sync
up to the cloud first — usually a few minutes, sometimes up to 30.

### Option A — let it wait for you (easiest)

```powershell
.\Add-OnboardUserLicense.ps1 -UserPrincipalName jsmith@contoso.com -Wait
```

This checks every minute until the account appears, then assigns the license. Leave it running.
Press Ctrl+C if you want to stop waiting.

### Option B — come back later

Go and do something else, then run:

```powershell
.\Add-OnboardUserLicense.ps1 -UserPrincipalName jsmith@contoso.com
```

If it is still not there, you will get a plain-English message saying so. Just try again in a
few minutes.

### What happens

A sign-in window opens and you log in with your own work account. The first time, it will ask
you to consent to permissions — that is expected.

```
==> Signing in to Microsoft 365
    [ ok ] Signed in to tenant a1b2c3d4-5678-90ab-cdef-1234567890ab

==> Looking for the account in Microsoft 365
    [ ok ] Found: John Smith <jsmith@contoso.com>

==> Adding to licensing group(s)
    [ ok ] Added to 'LIC-M365-E3'

 Licensing complete.
```

**This is safe to run more than once.** If the person is already in the group, it says
"Already a member" and does nothing.

The license takes a few minutes to appear on the account, and the mailbox takes a little longer
than that before it is usable.

---

## 11. Troubleshooting

### "...cannot be loaded because running scripts is disabled on this system"

Windows is blocking scripts. Run:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### "...is not digitally signed" or a script silently refuses to run

You downloaded the ZIP and Windows marked the files as blocked:

```powershell
Get-ChildItem -Path 'C:\Tools\MSPOnboardKit' -Recurse | Unblock-File
```

### "The term 'Get-ADUser' is not recognized"

The Active Directory tools are not installed. Go back to [section 3.2](#32-install-the-active-directory-tools-rsat).
If you just installed them, **close PowerShell and open it again** — it only loads modules at
startup.

### "The term 'Connect-MgGraph' is not recognized"

The Microsoft 365 tools are not installed. Go back to [section 3.4](#34-install-the-microsoft-365-tools).

### "Access is denied" when creating the user

Your account does not have permission to create users in that OU. This is not something you can
fix yourself — go back to [section 2](#2-permissions-you-need-before-you-start) and use the
email template.

### "Could not find the mirror user 'John Doe'"

Use the person's **username**, not their display name. `jdoe`, not `John Doe`, and not
`jdoe@contoso.com`. You can look it up:

```powershell
Get-ADUser -Filter "Name -like '*Doe*'" | Select-Object Name, SamAccountName
```

### "The target OU does not exist"

The `DefaultTargetOU` in your config file is wrong. It must be the exact distinguished name.
Go back to [Finding your OU](#finding-your-ou-the-defaulttargetou-value) and copy it again —
it is very easy to miss a character.

### "Start-ADSyncSyncCycle is not available on this machine"

Entra Connect is installed on a different server. You have three options:

1. Put that server's name in `AdSyncServer` in your config file
2. Add `-SkipSync` to your command and let the automatic sync happen on its own
3. Run the script on the Entra Connect server itself

The account was still created correctly either way. Entra Connect syncs by itself roughly every
30 minutes.

### "Sync is already running" / "cannot start a sync cycle"

Another sync was already in progress. This is harmless — yours will be picked up by the next
cycle. No action needed.

### "The account has not appeared in Microsoft 365 yet"

Normal if you have just created it. Wait a few minutes and run the licensing command again, or
use `-Wait`.

If it has still not arrived after 30 minutes, the sync is not running. Check with whoever
manages the Entra Connect server.

### "...is synchronised up from your on-premises Active Directory"

The licensing group was created in Active Directory and syncs up to Microsoft 365, which makes
it read-only in the cloud — nothing can add members to it there.

This cannot be fixed by changing permissions. You need a **different group**, created directly
in Entra ID:

1. Go to <https://entra.microsoft.com> → **Groups** → **New group**
2. Group type **Security**, membership type **Assigned**
3. Give it a name — `LIC-M365-E3` or similar
4. Attach the license to it (see [section 5](#5-one-time-microsoft-365-setup))
5. Put the new name in `Licensing.GroupNames` in your config file

The old on-prem group can stay where it is; it just is not used for licensing.

### "...uses dynamic membership"

The group decides its own members from a rule, so nobody can be added by hand.

Either switch the group's membership type to **Assigned** in Entra ID, or leave the rule alone
and let it pick up new hires by itself — in which case you do not need the licensing step at
all, and can skip it.

### "...is a distribution group" / "is not a security group"

Microsoft 365 only allows members to be added to **security groups** and **Microsoft 365
groups**. Create a Security group in Entra ID and attach the license to that one instead.

### "...does not appear to have any licences attached"

The group exists and members can be added, but no license is attached to it — so joining it
gives the new hire nothing.

An administrator needs to attach it: <https://entra.microsoft.com> → **Billing** → **Licenses**
→ **All products** → tick the license → **Assign** → choose the group.

If you know the license *is* attached, this may just mean your account cannot read that
setting. It is a warning rather than an error, so the script carries on regardless.

### "No group with this exact display name exists in Entra ID"

The name in `Licensing.GroupNames` does not match the real group name. It must match exactly,
including capitalisation and any hyphens. Check it at <https://entra.microsoft.com> under
**Groups**. If the group does not exist at all, an administrator needs to create it —
[section 5](#5-one-time-microsoft-365-setup).

### The email address came out wrong

Your `AliasTemplate` does not match your company's convention. Go back to
[Choosing your alias template](#choosing-your-alias-template), fix it, and confirm with:

```powershell
.\Test-OnboardKitSetup.ps1
```

The `AliasTemplate` line shows you exactly what a new hire would get.

### The person already had an account and now there are two

The toolkit adds a number when an address is taken, so a second John Smith becomes
`jsmith2@contoso.com`. If that was not what you wanted, delete the new account in Active
Directory Users and Computers and start again.

---

## 12. Glossary

**Active Directory (AD)** — the system that stores user accounts on your local network. It is
what people log into their computers with.

**ADUC** — Active Directory Users and Computers, the clicking-and-typing tool for managing
Active Directory. Open it by pressing Start and typing `dsa.msc`.

**OU (Organizational Unit)** — a folder inside Active Directory. Companies usually have
separate ones for staff, computers, service accounts, and so on.

**DN (Distinguished Name)** — the full technical address of something in Active Directory,
written as `OU=Users,OU=Company,DC=contoso,DC=com`. Read it right to left: the `DC` parts are
the domain, the `OU` parts are folders.

**UPN (User Principal Name)** — the username someone signs in with, which looks like an email
address: `jsmith@contoso.com`. This toolkit makes the UPN and the email address the same, which
is the normal arrangement.

**sAMAccountName** — the older, shorter username, like `jsmith`. Active Directory limits it to
**20 characters**, so a very long name gets shortened for this field only. The email address
keeps its full form.

**proxyAddresses** — a hidden field listing every email address an account can receive mail at.
One address is the *primary* — the one used when they send mail — and it is marked by writing
`SMTP:` in capitals. Everything else is lowercase `smtp:`. Getting this wrong is a classic
cause of email problems, which is why the toolkit sets it for you.

**Entra ID** — Microsoft 365's account system in the cloud. It used to be called Azure Active
Directory, so you will see both names around.

**Entra Connect** — the software that copies accounts from your local Active Directory up to
Entra ID. It normally runs by itself every 30 minutes.

**Delta sync** — a sync that copies only what has changed since last time, rather than
everything. It is fast, which is why the toolkit triggers one after creating an account.

**SKU** — Microsoft's word for a specific license product, for example *Microsoft 365 E3*.

**Group-based licensing** — assigning licenses to a group instead of to individuals. Anyone
added to the group automatically gets the license, and loses it if they are removed. This is
what the toolkit uses.

**Mirror user** — an existing employee whose group memberships get copied to a new hire.
Usually someone already doing the same job. It is optional.

**Dry run / `-WhatIf`** — running a command in a mode where it tells you what it would do but
changes nothing. Always safe.
