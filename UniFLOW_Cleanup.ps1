param(
    [Parameter(Mandatory=$true)]
    [string]$TenantDomain,  # e.g. "yourtenant.eu.uniflowonline.com"

    [Parameter(Mandatory=$true)]
    [string]$DisabledCsvPath,  # e.g. "C:\Temp\DisabledUsers.csv"

    [Parameter(Mandatory=$true)]
    [string]$LogPath,  # e.g. "C:\Temp\CardCleanup.log"

    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR')][string]$Level = 'INFO'
    )

    $prefix = @{
        INFO  = "ℹ️ "
        OK    = "✅"
        WARN  = "⚠️ "
        ERROR = "❌"
    }[$Level]

    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message

    Write-Host "$prefix $Message"
    Add-Content -Path $LogPath -Value $line
}

# --- GRAPH: connect + export disabled users ---

function Connect-Graph {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Import-Module Microsoft.Graph.Users -ErrorAction Stop

    $scopes = @('User.Read.All', 'Directory.Read.All')
    Write-Log "Connecting to Microsoft Graph..." "INFO"
    Connect-MgGraph -Scopes $scopes | Out-Null
    Write-Log "Connected to Microsoft Graph." "OK"
}

function Export-DisabledEntraUsers {
    param([Parameter(Mandatory=$true)][string]$Path)

    Write-Log "Querying disabled Entra users (accountEnabled eq false)..." "INFO"

    $disabled = Get-MgUser -All `
        -Filter "accountEnabled eq false" `
        -Property "id,displayName,userPrincipalName,mail,accountEnabled" |
        Select-Object `
            @{n="Id";e={$_.Id}},
            @{n="DisplayName";e={$_.DisplayName}},
            @{n="UserPrincipalName";e={$_.UserPrincipalName}},
            @{n="Mail";e={$_.Mail}},
            @{n="AccountEnabled";e={$_.AccountEnabled}}

    $disabled | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    Write-Log "Exported $($disabled.Count) disabled users to '$Path'." "OK"

    return $disabled
}

# --- uniFLOW: connect + fetch users with sCardNumber ---

function Connect-UniFLOW {
    Import-Module NTware.Ufo.PowerShell.ObjectManagement -ErrorAction Stop

    Write-Log "Connecting to uniFLOW Online tenant '$TenantDomain'..." "INFO"
    Open-MomoConnection -TenantDomain $TenantDomain -Interactive | Out-Null
    Write-Log "Connected to uniFLOW Online." "OK"
}

function Get-UniFLOWUsersWithCardNumberType {
    Write-Log "Fetching uniFLOW users with IdentityType 'sCardNumber'..." "INFO"
    $ufoUsers = Find-MomoUsers -FilterName IdentityType -FilterValue 'sCardNumber'
    Write-Log "uniFLOW returned $($ufoUsers.Count) users with 'sCardNumber'." "OK"
    return $ufoUsers
}

# --- Remove card identities by email ---

function Remove-CardIdentityByEmail {
    param(
        [Parameter(Mandatory=$true)][string]$Email
    )

    if ($WhatIf) {
        Write-Log "[WhatIf] Would run Remove-MomoUserIdentity for '$Email' (CardNumber, DeleteAllIdentitiesOfType)." "INFO"
        return
    }

    try {
        Remove-MomoUserIdentity -Email $Email -IdentityType 'CardNumber' -DeleteAllIdentitiesOfType | Out-Null
        Write-Log "Removed CardNumber identities for '$Email'." "OK"
    }
    catch {
        Write-Log "FAILED removing CardNumber identities for '$Email': $($_.Exception.Message)" "ERROR"
    }
}

# ------------------- MAIN -------------------

# Init log file
"==== Run started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====" | Out-File -FilePath $LogPath -Encoding UTF8

try {
    Connect-Graph
    $disabledUsers = Export-DisabledEntraUsers -Path $DisabledCsvPath

    Connect-UniFLOW
    $ufoCardUsers = Get-UniFLOWUsersWithCardNumberType

    # Build lookup: NotificationEmail -> uniFLOW user(s)
    # (case-insensitive)
    $ufoByEmail = @{}
    foreach ($u in $ufoCardUsers) {
        $ne = $u.NotificationEmail
        if ([string]::IsNullOrWhiteSpace($ne)) { continue }

        $key = $ne.Trim().ToLowerInvariant()
        if (-not $ufoByEmail.ContainsKey($key)) { $ufoByEmail[$key] = @() }
        $ufoByEmail[$key] += $u
    }

    Write-Log "Built lookup for $($ufoByEmail.Keys.Count) distinct uniFLOW NotificationEmail values." "INFO"

    # Match disabled Entra users (by Mail) to uniFLOW NotificationEmail
    $matches = New-Object System.Collections.Generic.List[object]

    foreach ($adu in $disabledUsers) {
        $mail = $adu.Mail
        if ([string]::IsNullOrWhiteSpace($mail)) {
            Write-Log "Skipping '$($adu.DisplayName)' ($($adu.UserPrincipalName)) because Mail is empty." "WARN"
            continue
        }

        $key = $mail.Trim().ToLowerInvariant()
        if ($ufoByEmail.ContainsKey($key)) {
            $matches.Add([pscustomobject]@{
                EntraDisplayName = $adu.DisplayName
                EntraUPN         = $adu.UserPrincipalName
                EntraMail        = $mail
                UniFLOWHits      = $ufoByEmail[$key].Count
            })
            Write-Log "MATCH: Disabled Entra user '$mail' found in uniFLOW (hits: $($ufoByEmail[$key].Count))." "OK"
        } else {
            Write-Log "No match for disabled Entra user '$mail' in uniFLOW NotificationEmail." "INFO"
        }
    }

    Write-Log "Total matches: $($matches.Count)" "INFO"

    # Process removals
    foreach ($m in $matches) {
        Write-Log "Processing removal for '$($m.EntraMail)' (UniFLOWHits=$($m.UniFLOWHits))..." "INFO"
        Remove-CardIdentityByEmail -Email $m.EntraMail
    }

    Write-Log "Run complete." "OK"
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)" "ERROR"
    throw
}
finally {
    if (Get-Command Close-MomoConnection -ErrorAction SilentlyContinue) {
        try { Close-MomoConnection | Out-Null } catch {}
    }
    Write-Log "==== Run ended ====" "INFO"
}
