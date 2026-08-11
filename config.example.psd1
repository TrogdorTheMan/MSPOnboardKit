<#
    MSPOnboardKit - example configuration

    HOW TO USE THIS FILE
      1. Make a copy of it in this same folder and name the copy  config.psd1
      2. Replace every placeholder value below with your own
      3. Save it

    config.psd1 is listed in .gitignore, so your real values will never be
    committed or published. Do not put real values in THIS file.

    Every setting is explained in the comment above it. If you are unsure
    where to find a value, docs/SETUP.md section 6 tells you exactly where
    to look for each one.

    Text values go inside single quotes: 'like this'
    Lists go inside @( ) with commas: @('One', 'Two')
    An empty list is just: @()
#>

@{

    # -----------------------------------------------------------------------
    # REQUIRED - your email domain.
    # This is the part that comes AFTER the @ sign in your staff email
    # addresses. If your staff use john.smith@contoso.com, put 'contoso.com'
    # -----------------------------------------------------------------------
    Domain = 'example.com'

    # -----------------------------------------------------------------------
    # REQUIRED - how to build the email alias from a new hire's name.
    #
    #   {first}    the whole first name
    #   {last}     the whole last name
    #   {first:1}  just the first 1 letter of the first name
    #   {last:7}   just the first 7 letters of the last name
    #
    # For a new hire named John Smith:
    #
    #   '{first:1}{last}'   ->  jsmith@example.com
    #   '{first}.{last}'    ->  john.smith@example.com
    #   '{first}{last}'     ->  johnsmith@example.com
    #   '{first}{last:1}'   ->  johns@example.com
    #
    # Accents and punctuation are removed automatically, so O'Brien becomes
    # obrien and Jose becomes jose.
    # -----------------------------------------------------------------------
    AliasTemplate = '{first:1}{last}'

    # -----------------------------------------------------------------------
    # REQUIRED - where new user accounts get created in Active Directory.
    #
    # This is called a "distinguished name" and it must be exact. It is not
    # something you can guess - copy it out of Active Directory Users and
    # Computers. docs/SETUP.md section 6 shows you how, with screenshots
    # described step by step.
    # -----------------------------------------------------------------------
    DefaultTargetOU = 'OU=Users,OU=Company,DC=example,DC=com'

    # -----------------------------------------------------------------------
    # OPTIONAL - groups every new hire should get when NO mirror user is
    # given on the command line.
    #
    # A "mirror user" is an existing employee whose group memberships get
    # copied to the new hire. When you supply one, this list is ignored.
    # When you do not supply one, the new hire gets exactly these groups.
    #
    # Leave it as @() if you would rather add groups manually in that case.
    # -----------------------------------------------------------------------
    DefaultGroups = @(
        'All Staff'
    )

    # -----------------------------------------------------------------------
    # OPTIONAL - the server that runs Entra Connect (the tool that copies
    # your on-premises accounts up to Microsoft 365).
    #
    # Leave this as '' (empty) if the script will be run ON that same server.
    # If Entra Connect runs somewhere else, put that server's name here and
    # the sync will be triggered remotely.
    #
    # Not sure? Leave it empty and run Test-OnboardKitSetup.ps1 - it will
    # tell you whether the sync command is available where you are.
    # -----------------------------------------------------------------------
    AdSyncServer = ''

    # -----------------------------------------------------------------------
    # OPTIONAL - length of the generated temporary password.
    # Must be at least 12. The new hire is forced to change it at first
    # logon, so longer is fine.
    # -----------------------------------------------------------------------
    TempPasswordLength = 16

    # -----------------------------------------------------------------------
    # Microsoft 365 licensing.
    #
    # IMPORTANT: this toolkit does NOT create these groups or assign license
    # SKUs to them. That is a one-time setup job for whoever administers your
    # Microsoft 365 tenant - see docs/SETUP.md section 5.
    #
    # Put the DISPLAY NAMES of the already-existing Entra ID groups that
    # already hand out licenses. Adding the new hire to these groups is what
    # gives them their license.
    # -----------------------------------------------------------------------
    Licensing = @{

        GroupNames = @(
            'LIC-M365-E3'
        )
    }

    # -----------------------------------------------------------------------
    # How the licensing script signs in to Microsoft 365.
    # -----------------------------------------------------------------------
    Graph = @{

        # 'Delegated'       - a sign-in window opens and YOU log in with your
        #                     own work account. Simplest, nothing to store.
        #                     Recommended unless you have a reason not to.
        #
        # 'AppRegistration' - signs in as a registered application with no
        #                     human involved. Only needed for fully
        #                     unattended automation. Requires a tenant admin
        #                     to set up an app registration first.
        AuthMode = 'Delegated'

        # Your Microsoft 365 tenant ID (a long code that looks like
        # 00000000-0000-0000-0000-000000000000).
        # docs/SETUP.md section 6 shows where to find it in the admin portal.
        TenantId = '00000000-0000-0000-0000-000000000000'

        # ---- The settings below are ONLY used when AuthMode is
        # ---- 'AppRegistration'. Leave them empty for 'Delegated'.

        # The Application (client) ID of the app registration.
        ClientId = ''

        # Preferred: the thumbprint of a certificate installed on this
        # machine that the app registration trusts.
        CertificateThumbprint = ''

        # Fallback if you cannot use a certificate.
        #
        # NOTE CAREFULLY: this is the NAME of an environment variable that
        # holds the client secret - it is NOT the secret itself. Never put an
        # actual password or secret in this file.
        #
        # Example: set the environment variable ONBOARDKIT_CLIENT_SECRET to
        # the secret value, then put 'ONBOARDKIT_CLIENT_SECRET' here.
        ClientSecretEnvVar = ''
    }
}
