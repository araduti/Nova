# Code Signing with Azure Trusted Signing

Nova uses [Azure Trusted Signing](https://learn.microsoft.com/en-us/azure/trusted-signing/) to digitally sign PowerShell scripts and modules with Authenticode signatures. Signed scripts ensure integrity and authenticity, allowing environments with strict execution policies (e.g., `AllSigned`) to run them without modification.

## What Gets Signed

All production PowerShell scripts and modules are signed:

| File | Type |
|------|------|
| `src/scripts/Trigger.ps1` | Entry-point script |
| `src/scripts/Bootstrap.ps1` | Bootstrap script |
| `src/scripts/Nova.ps1` | Main deployment script |
| `src/modules/Nova.ADK/Nova.ADK.psm1` | ADK management module |
| `src/modules/Nova.Auth/Nova.Auth.psm1` | Authentication module |
| `src/modules/Nova.BuildConfig/Nova.BuildConfig.psm1` | Build configuration module |
| `src/modules/Nova.Integrity/Nova.Integrity.psm1` | Integrity verification module |
| `src/modules/Nova.Logging/Nova.Logging.psm1` | Logging module |
| `src/modules/Nova.Network/Nova.Network.psm1` | Network utilities module |
| `src/modules/Nova.Platform/Nova.Platform.psm1` | Platform detection module |
| `src/modules/Nova.WinRE/Nova.WinRE.psm1` | WinRE management module |
| `resources/autopilot/Utils.ps1` | Autopilot utilities |
| `resources/autopilot/Invoke-ImportAutopilot.ps1` | Autopilot import script |

Test files under `tests/` are excluded from signing.

## When Signing Occurs

- **Release workflow** (`release.yml`): All scripts are signed after tests pass. Signed scripts are packaged into a `nova-signed-scripts.zip` artifact and attached to the GitHub Release. Hashes in `config/hashes.json` are regenerated to reflect the signed file contents.
- **CI workflow** (`ci.yml`): On pushes to `main` (not on pull requests), only scripts that changed in the push are signed (incremental signing). On the initial push or when the base commit is unavailable, all scripts are signed. Signed artifacts are uploaded with a 7-day retention period.

## Azure Setup

### 1. Create a Trusted Signing Account

1. In the Azure Portal, create a **Trusted Signing** resource
2. Create a **Certificate Profile** within the account (use the `Public Trust` or `Private Trust` profile type as needed)
3. Note the **endpoint URL** (e.g., `https://eus.codesigning.azure.net`)

### 2. Create an Entra ID App Registration

1. In Microsoft Entra ID, create an **App Registration**
2. Add a **Federated Credential** for GitHub Actions OIDC:
   - Issuer: `https://token.actions.githubusercontent.com`
   - Subject: `repo:<owner>/<repo>:ref:refs/heads/main` (for CI)
   - Subject: `repo:<owner>/<repo>:ref:refs/tags/*` (add a second credential for releases)
   - Audience: `api://AzureADTokenExchange`
3. Grant the app the **Trusted Signing Certificate Profile Signer** role on the Trusted Signing account

### 3. Configure GitHub Repository Secrets

Add the following secrets in **Settings → Secrets and variables → Actions**:

| Secret | Description | Example |
|--------|-------------|---------|
| `AZURE_CLIENT_ID` | Entra ID app registration client ID | `12345678-abcd-...` |
| `AZURE_TENANT_ID` | Entra ID tenant ID | `87654321-dcba-...` |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID | `abcdef01-2345-...` |
| `TRUSTED_SIGNING_ENDPOINT` | Trusted Signing endpoint URL | `https://eus.codesigning.azure.net` |
| `TRUSTED_SIGNING_ACCOUNT_NAME` | Trusted Signing account name | `my-signing-account` |
| `TRUSTED_SIGNING_CERTIFICATE_PROFILE_NAME` | Certificate profile name | `my-cert-profile` |

## Verifying Signatures

On a Windows machine, verify a signed script:

```powershell
Get-AuthenticodeSignature -FilePath .\src\scripts\Nova.ps1

# Expected output:
# SignerCertificate  Status   Path
# -----------------  ------   ----
# <thumbprint>       Valid    Nova.ps1
```

Or inspect the signature details:

```powershell
$sig = Get-AuthenticodeSignature -FilePath .\src\scripts\Nova.ps1
$sig.SignerCertificate | Format-List Subject, Issuer, NotBefore, NotAfter
```

## Execution Policy Compatibility

Once scripts are signed, endpoints can use stricter execution policies:

```powershell
# Require all scripts to be signed
Set-ExecutionPolicy -ExecutionPolicy AllSigned -Scope LocalMachine

# Or require only remote scripts to be signed
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine
```

## Hash Integrity

After signing, scripts contain an embedded Authenticode signature block which changes their SHA256 hash. The release workflow automatically regenerates `config/hashes.json` with the post-signing hashes, so hash validation remains consistent for signed distributions.
