# Entra Disabled User → uniFLOW CardNumber Cleanup

This PowerShell script helps you clean up **uniFLOW Online CardNumber identities** for users that are **disabled in Entra ID**.

It:
1. Connects to **Microsoft Graph**
2. Exports all **disabled Entra users** (`accountEnabled eq false`) to CSV
3. Connects to **uniFLOW Online**
4. Fetches uniFLOW users with **IdentityType = `sCardNumber`** (currently there is no way to filter deactivated users)
5. Matches **Entra `Mail`** to uniFLOW **`NotificationEmail`**
6. For matches, runs:
   - `Remove-MomoUserIdentity -Email <mail> -IdentityType 'CardNumber' -DeleteAllIdentitiesOfType`
7. Logs everything to a file (and prints friendly status to the console)

---

## Why this exists

When a user is disabled in Entra, you often want to also remove their physical card identity from uniFLOW Online to reuse of the card by new users.
UniFLOW Online only deactivates accounts when a provisioned user is deleted or deactivated, this means the card is still linked to the deactivated account, and cannot be used until either the account, or card identity is deleted

It can be quite time consuming trying to find which specific card identity needs to be recycled, so this script just nukes them all!

---

## Requirements

### PowerShell
- Windows PowerShell **5.1** (works fine there)

### Microsoft Graph PowerShell modules
- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Users`

### uniFLOW Online PowerShell module
- `NTware.Ufo.PowerShell.ObjectManagement`

You’ll need permissions to:
- Read users in Entra ID (Graph scopes)
- Connect to the uniFLOW tenant and remove identities

---

## Permissions / Scopes

The script connects to Graph with:
- `User.Read.All`
- `Directory.Read.All`

---

## Usage

### Example
```powershell
.\Entra-UniFLOW-CardCleanup.ps1 `
  -TenantDomain "yourtenant.eu.uniflowonline.com" `
  -DisabledCsvPath "C:\Temp\DisabledUsers.csv" `
  -LogPath "C:\Temp\CardCleanup.log" `
  -WhatIf
