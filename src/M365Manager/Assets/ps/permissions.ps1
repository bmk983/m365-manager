# ------------------------------------------------------------------------------
#  M365 Manager · Graph-Berechtigungen
#  Zentrale Registry (Funktion -> Scopes/Rollen), Auswertung des tatsächlich verwendeten Tokens,
#  Preflight vor privilegierten Aktionen und strukturierte Fehlerdiagnose.
#  Es werden niemals Tokens ausgegeben oder protokolliert – nur deren Claims (Scopes, Zeiten, IDs).
# ------------------------------------------------------------------------------

$global:M365GraphClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'   # Microsoft Graph Command Line Tools
$global:M365GraphResourceAppId = '00000003-0000-0000-c000-000000000000'
# Standard-Benutzerrollen (stehen in jedem Token/jeder Mitgliedschaft, sind keine Admin-Rollen)
$global:M365DefaultUserRoleIds = @('a0b1b346-4d3e-4e8b-98f8-753987be4970', 'b79fbf4d-3ef9-4689-8143-76b194e85509')

# Eingebaute Entra-Rollen (Template-IDs sind in allen Tenants gleich)
$global:M365Roles = [ordered]@{
    GlobalAdministrator                   = @{ Id = '62e90394-69f5-4237-9190-012177145e10'; Name = 'Global Administrator' }
    PrivilegedAuthenticationAdministrator = @{ Id = '7be44c8a-adaf-4e2a-84d6-ab2649e08a13'; Name = 'Privileged Authentication Administrator' }
    PrivilegedRoleAdministrator           = @{ Id = 'e8611ab8-c189-46e8-94e1-60213ab1f814'; Name = 'Privileged Role Administrator' }
    AuthenticationAdministrator           = @{ Id = 'c4e39bd9-1100-46d3-8c65-fb160da0071f'; Name = 'Authentication Administrator' }
    UserAdministrator                     = @{ Id = 'fe930be7-5e62-47db-91af-98c3a49a38b1'; Name = 'User Administrator' }
    HelpdeskAdministrator                 = @{ Id = '729827e3-9c14-49f7-bb1b-9608f156bbb8'; Name = 'Helpdesk Administrator' }
    PasswordAdministrator                 = @{ Id = '966707d0-3269-4727-9be2-8c3a10f19b9d'; Name = 'Password Administrator' }
    SecurityAdministrator                 = @{ Id = '194ae4cb-b126-40b2-bd5b-6091b380977d'; Name = 'Security Administrator' }
    SecurityReader                        = @{ Id = '5d6b6bb7-de71-4623-b4af-96380a352509'; Name = 'Security Reader' }
    GlobalReader                          = @{ Id = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'; Name = 'Global Reader' }
    ReportsReader                         = @{ Id = '4a5d8f65-41da-4de4-8968-e035b65339cf'; Name = 'Reports Reader' }
    DirectoryReaders                      = @{ Id = '88d8e3e3-8f55-4a1e-953a-9b9898b8876b'; Name = 'Directory Readers' }
    GuestInviter                          = @{ Id = '95e79109-95c0-4d8e-aee3-d01accf2d47b'; Name = 'Guest Inviter' }
    MessageCenterReader                   = @{ Id = '790c1fb9-7f7d-4f88-86a1-ef1f95c05c1b'; Name = 'Message Center Reader' }
    UsageSummaryReportsReader             = @{ Id = '75934031-6c7e-415a-99d7-48dbd49e875e'; Name = 'Usage Summary Reports Reader' }
    ApplicationAdministrator              = @{ Id = '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3'; Name = 'Application Administrator' }
    ExchangeAdministrator                 = @{ Id = '29232cdf-9323-42fd-ade2-1d097af3e4de'; Name = 'Exchange Administrator' }
    GroupsAdministrator                   = @{ Id = 'fdd7a751-b60b-444a-984c-02652fe8fa1c'; Name = 'Groups Administrator' }
    IntuneAdministrator                   = @{ Id = '3a2c62db-5318-420d-8d74-23affee5d9d5'; Name = 'Intune Administrator' }
    SharePointAdministrator               = @{ Id = 'f28a1f50-f6e7-4571-818b-6a12f2af6b6c'; Name = 'SharePoint Administrator' }
}

function Get-M365RoleId([string]$Key) { $global:M365Roles[$Key].Id }

# Kennzeichen für Schutzgründe, die keine Rolle sind
$global:M365ProtectionMarkers = @{
    'role-assignable-group' = 'Mitglied einer rollenzuweisbaren Gruppe'
    'restricted-au'         = 'in einer Verwaltungseinheit mit eingeschränkter Verwaltung'
}
$global:M365RoleNameCache = $null

function Get-M365RoleName([string]$Id) {
    foreach ($r in $global:M365Roles.Values) { if ($r.Id -eq $Id) { return $r.Name } }
    if ($global:M365ProtectionMarkers.ContainsKey($Id)) { return $global:M365ProtectionMarkers[$Id] }
    # Unbekannte Rolle (z. B. Dynamics 365 Business Central Administrator): Namen einmalig aus dem Verzeichnis laden
    if ($null -eq $global:M365RoleNameCache) {
        $global:M365RoleNameCache = @{}
        try {
            foreach ($d in (Invoke-M365GraphGet 'v1.0/roleManagement/directory/roleDefinitions?$select=id,templateId,displayName').value) {
                $global:M365RoleNameCache["$($d.templateId)"] = $d.displayName
                $global:M365RoleNameCache["$($d.id)"] = $d.displayName
            }
        }
        catch { }
    }
    if ($global:M365RoleNameCache.ContainsKey($Id)) { return $global:M365RoleNameCache[$Id] }
    return $Id
}

# Welche Zielrollen darf eine Rolle verwalten? '*' = alle. (Nach Microsoft-Doku "Who can perform sensitive actions";
# die endgültige Entscheidung trifft immer Microsoft Graph – die Prüfung hier dient der verständlichen Vorwarnung.)
$global:M365TargetRules = @{
    AuthMethods = [ordered]@{
        GlobalAdministrator                   = '*'
        PrivilegedAuthenticationAdministrator = '*'
        AuthenticationAdministrator           = @('AuthenticationAdministrator', 'DirectoryReaders', 'GuestInviter', 'HelpdeskAdministrator', 'MessageCenterReader', 'PasswordAdministrator', 'ReportsReader', 'UsageSummaryReportsReader')
    }
    Sessions = [ordered]@{
        GlobalAdministrator                   = '*'
        PrivilegedAuthenticationAdministrator = '*'
        UserAdministrator                     = @('DirectoryReaders', 'GuestInviter', 'HelpdeskAdministrator', 'MessageCenterReader', 'PasswordAdministrator', 'ReportsReader', 'UsageSummaryReportsReader', 'UserAdministrator')
        AuthenticationAdministrator           = @('AuthenticationAdministrator', 'DirectoryReaders', 'GuestInviter', 'HelpdeskAdministrator', 'MessageCenterReader', 'PasswordAdministrator', 'ReportsReader', 'UsageSummaryReportsReader')
        HelpdeskAdministrator                 = @('DirectoryReaders', 'GuestInviter', 'HelpdeskAdministrator', 'MessageCenterReader', 'PasswordAdministrator', 'ReportsReader', 'UsageSummaryReportsReader')
    }
}

# ------------------------------------------------------------------ Registry: Funktion -> Berechtigungen
# Least  = was angefordert wird (kleinstmöglich)
# Accept = was im Token als ausreichend akzeptiert wird (inkl. kompatibler höherer Scopes)
# Roles  = Entra-Rollen, mit denen die Funktion laut Microsoft möglich ist (Hinweis, Graph entscheidet)
$global:M365Permissions = [ordered]@{
    'AuthMethods.Read'  = @{
        Title    = 'Authentifizierungsmethoden lesen'
        Least    = @('UserAuthenticationMethod.Read.All')
        Accept   = @('UserAuthenticationMethod.Read.All', 'UserAuthenticationMethod.ReadWrite.All')
        Roles    = @('AuthenticationAdministrator', 'PrivilegedAuthenticationAdministrator', 'GlobalAdministrator', 'GlobalReader', 'SecurityReader', 'SecurityAdministrator')
        Rule     = $null
        Pattern  = '^Get-Mg(Beta)?UserAuthentication'
        Endpoint = 'GET /v1.0/users/{id}/authentication/methods'
    }
    'AuthMethods.Write' = @{
        Title    = 'Authentifizierungsmethoden verwalten'
        Least    = @('UserAuthenticationMethod.ReadWrite.All')
        Accept   = @('UserAuthenticationMethod.ReadWrite.All')
        Roles    = @('AuthenticationAdministrator', 'PrivilegedAuthenticationAdministrator', 'GlobalAdministrator')
        Rule     = 'AuthMethods'
        Pattern  = '^(New|Update|Remove|Reset|Enable|Disable)-Mg(Beta)?UserAuthentication'
        Endpoint = '/v1.0/users/{id}/authentication/…'
    }
    'Sessions.Revoke'   = @{
        Title    = 'Sessions widerrufen'
        Least    = @('User.RevokeSessions.All')
        Accept   = @('User.RevokeSessions.All', 'User.ReadWrite.All', 'Directory.ReadWrite.All')
        Roles    = @('UserAdministrator', 'HelpdeskAdministrator', 'AuthenticationAdministrator', 'PrivilegedAuthenticationAdministrator', 'GlobalAdministrator')
        Rule     = 'Sessions'
        Pattern  = '^Revoke-Mg(Beta)?UserSignInSession$'
        Endpoint = 'POST /v1.0/users/{id}/revokeSignInSessions'
    }
    'AuditLogs.Read'    = @{
        Title    = 'Audit-Logs lesen'
        Least    = @('AuditLog.Read.All')
        Accept   = @('AuditLog.Read.All')
        Roles    = @('ReportsReader', 'SecurityReader', 'SecurityAdministrator', 'GlobalReader', 'GlobalAdministrator')
        Rule     = $null
        Pattern  = '^Get-Mg(Beta)?AuditLog'
        Endpoint = 'GET /v1.0/auditLogs/directoryAudits'
    }
}

function Get-M365OperationForCommand([string]$CommandName) {
    foreach ($key in $global:M365Permissions.Keys) {
        if ($CommandName -match $global:M365Permissions[$key].Pattern) { return $key }
    }
    return $null
}

# ------------------------------------------------------------------ Token-Claims (ohne das Token selbst)
function ConvertFrom-M365Jwt([string]$Token) {
    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { throw 'Kein gültiges JWT.' }
    $payload = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    $account = if ($json.upn) { $json.upn } elseif ($json.preferred_username) { $json.preferred_username } else { $json.unique_name }
    [pscustomobject]@{
        Scopes    = @("$($json.scp)".Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
        TenantId  = $json.tid
        ClientId  = if ($json.appid) { $json.appid } else { $json.azp }
        Account   = $account
        ObjectId  = $json.oid
        RoleIds   = @($json.wids | Where-Object { $_ -and $global:M365DefaultUserRoleIds -notcontains $_ })
        IssuedAt  = if ($json.iat) { [DateTimeOffset]::FromUnixTimeSeconds([long]$json.iat) } else { $null }
        ExpiresAt = if ($json.exp) { [DateTimeOffset]::FromUnixTimeSeconds([long]$json.exp) } else { $null }
        Source    = 'Broker'
    }
}

# Merkt sich die Claims des aktuell im Terminal verwendeten Graph-Tokens.
function Set-M365GraphTokenInfo($Info) { $global:M365.GraphToken = $Info }

function Get-M365GraphTokenInfo {
    $info = $global:M365.GraphToken
    if ($info) { return $info }
    # Kein selbst ausgestelltes Token bekannt (z. B. klassische Modul-Anmeldung): was Graph selbst meldet
    if (Get-Module Microsoft.Graph.Authentication) {
        $ctx = Get-MgContext
        if ($ctx) {
            return [pscustomobject]@{
                Scopes = @($ctx.Scopes); TenantId = $ctx.TenantId; ClientId = $ctx.ClientId; Account = $ctx.Account; ObjectId = $null
                RoleIds = $null; IssuedAt = $null; ExpiresAt = $null; Source = "Modul ($($ctx.AuthType))"
            }
        }
    }
    return $null
}

# Kann die App selbst ein neues Token mit zusätzlichen Scopes besorgen?
function Test-M365ScopeEscalation($Info) {
    if (-not $Info) { return $false }
    if ($Info.Source -eq 'Broker') { return [bool]$env:M365M_PIPE }      # App-Broker: inkrementeller Consent im Profil-Browser
    if ("$($Info.Source)" -like 'Modul (Delegated*') { return $true }       # klassische Modul-Anmeldung: Connect-MgGraph -Scopes
    return $false                                                            # extern übergebenes Token (UserProvidedAccessToken)
}

# ------------------------------------------------------------------ Graph-Abfragen (in Tests ersetzbar)
function Invoke-M365GraphGet([string]$Uri) {
    Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject -ErrorAction Stop
}

$global:M365ConsentCache = $null
# Für diesen Benutzer bzw. tenantweit erteilte delegierte Scopes der Graph-CLI-App (best effort; $null = unbekannt).
function Get-M365ConsentedGraphScopes([switch]$Refresh) {
    if (-not $Refresh -and $global:M365ConsentCache -and $global:M365ConsentCache.At -gt (Get-Date).AddMinutes(-5)) { return $global:M365ConsentCache.Scopes }
    try {
        $info = Get-M365GraphTokenInfo
        $client = Invoke-M365GraphGet "v1.0/servicePrincipals(appId='$($global:M365GraphClientId)')?`$select=id"
        $graph = Invoke-M365GraphGet "v1.0/servicePrincipals(appId='$($global:M365GraphResourceAppId)')?`$select=id"
        $grants = Invoke-M365GraphGet "v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($client.id)'"
        $scopes = @($grants.value | Where-Object {
                $_.resourceId -eq $graph.id -and ($_.consentType -eq 'AllPrincipals' -or ($info -and $_.principalId -eq $info.ObjectId))
            } | ForEach-Object { "$($_.scope)".Split(' ', [StringSplitOptions]::RemoveEmptyEntries) } | Sort-Object -Unique)
        $global:M365ConsentCache = @{ At = Get-Date; Scopes = $scopes }
        return $scopes
    }
    catch { return $null }
}

# Aktive Rollen des angemeldeten Benutzers: aus dem Token (wids), sonst per Graph.
function Get-M365CallerRoleIds($Info) {
    if ($Info -and $Info.RoleIds) { return @($Info.RoleIds) }
    try { return @((Invoke-M365GraphGet 'v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=roleTemplateId').value.roleTemplateId) }
    catch { return $null }
}

# Aktuell aktive Rollen direkt aus dem Verzeichnis – unabhängig davon, was im (evtl. älteren) Token steht.
function Get-M365LiveRoleIds {
    try { return @((Invoke-M365GraphGet 'v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=roleTemplateId').value.roleTemplateId) }
    catch { return $null }
}

# Alles, was ein Zielkonto für Microsoft "privilegiert" macht. $null = unbekannt.
#  - aktive Rollen (direkt und über Gruppen)
#  - per PIM berechtigte Rollen (auch wenn gerade nicht aktiv)
#  - Mitgliedschaft in einer rollenzuweisbaren Gruppe
#  - Mitgliedschaft in einer Verwaltungseinheit mit eingeschränkter Verwaltung
function Get-M365TargetRoleIds([string]$UserId) {
    if (-not $UserId) { return $null }
    $id = [uri]::EscapeDataString($UserId)
    try {
        $user = Invoke-M365GraphGet "v1.0/users/$id`?`$select=id"
        $result = [System.Collections.Generic.List[string]]::new()
        foreach ($r in (Invoke-M365GraphGet "v1.0/users/$($user.id)/transitiveMemberOf/microsoft.graph.directoryRole?`$select=roleTemplateId").value) { $result.Add("$($r.roleTemplateId)") }
        try { foreach ($e in (Invoke-M365GraphGet "v1.0/roleManagement/directory/roleEligibilityScheduleInstances?`$filter=principalId eq '$($user.id)'").value) { $result.Add("$($e.roleDefinitionId)") } } catch { }
        # Direkte Zuweisungen inkl. benutzerdefinierter Rollen (die erscheinen nicht als directoryRole)
        try { foreach ($a in (Invoke-M365GraphGet "v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($user.id)'").value) { $result.Add("$($a.roleDefinitionId)") } } catch { }
        try {
            if (@((Invoke-M365GraphGet "v1.0/users/$($user.id)/transitiveMemberOf/microsoft.graph.group?`$select=id,isAssignableToRole").value | Where-Object { $_.isAssignableToRole }).Count) { $result.Add('role-assignable-group') }
        } catch { }
        try {
            if (@((Invoke-M365GraphGet "v1.0/users/$($user.id)/memberOf/microsoft.graph.administrativeUnit?`$select=id,isMemberManagementRestricted").value | Where-Object { $_.isMemberManagementRestricted }).Count) { $result.Add('restricted-au') }
        } catch { }
        return @($result | Where-Object { $_ } | Select-Object -Unique)
    }
    catch { return $null }
}

# ------------------------------------------------------------------ Bewertung (reine Funktion, testbar)
function Get-M365OperationStatus {
    param(
        [Parameter(Mandatory)][string]$Operation,
        $Token,
        $ConsentedScopes,
        $CallerRoleIds,
        $TargetRoleIds,
        $LiveRoleIds,      # aktuell aktive Rollen laut Verzeichnis (erkennt PIM-Aktivierungen nach Token-Ausstellung)
        [string]$TargetUser,
        [bool]$EscalationSupported = $true,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    $def = $global:M365Permissions[$Operation]
    if (-not $def) { throw "Unbekannte Funktion: $Operation" }

    $r = [ordered]@{
        Operation = $Operation; Title = $def.Title; Status = 'Allowed'; Message = ''
        RequiredScopes = $def.Least; AcceptedScopes = $def.Accept; TokenScopes = @(); MissingScopes = @(); RequestScopes = @()
        AuthorizedByScope = $null; AuthorizedByRole = $null; CallerRoles = @(); TargetUser = $TargetUser; TargetRoles = @(); Endpoint = $def.Endpoint
    }
    $done = { param($status, $msg) $r.Status = $status; $r.Message = $msg; [pscustomobject]$r }

    if (-not $Token) { return & $done 'FreshTokenRequired' 'Microsoft Graph ist in dieser Sitzung nicht verbunden. Bitte zuerst verbinden (Connect-M365 Graph).' }
    $r.TokenScopes = @($Token.Scopes)
    if ($Token.ExpiresAt -and $Token.ExpiresAt -le $Now) { return & $done 'FreshTokenRequired' 'Der Access Token ist abgelaufen. Bitte neu authentifizieren.' }

    $matched = @($def.Accept | Where-Object { $r.TokenScopes -contains $_ })
    if ($matched) { $r.AuthorizedByScope = $matched[0] }
    else {
        $r.MissingScopes = @($def.Least)
        $r.RequestScopes = @($def.Least)
        $consented = $null -ne $ConsentedScopes -and @($def.Accept | Where-Object { $ConsentedScopes -contains $_ }).Count -gt 0
        $roleHint = ''
        if ($CallerRoleIds) {
            $have = @($def.Roles | Where-Object { $CallerRoleIds -contains (Get-M365RoleId $_) })
            if ($have) { $roleHint = " Der Benutzer besitzt zwar die Rolle $((Get-M365RoleName (Get-M365RoleId $have[0]))), aber Rolle und Graph-Scope werden beide benötigt." }
        }
        $scopeText = $def.Least -join ', '
        if ($consented) {
            return & $done 'FreshTokenRequired' "Der verwendete Access Token wurde vor der Berechtigungserweiterung ausgestellt ($scopeText ist erteilt, steht aber nicht im Token). Bitte die Graph-Sitzung neu authentifizieren."
        }
        if (-not $EscalationSupported) {
            return & $done 'UnsupportedAuthenticationFlow' "Dem Access Token fehlt $scopeText. Das Token wurde extern übergeben (UserProvidedAccessToken) – die App kann dafür selbst keine zusätzlichen Berechtigungen anfordern. Bitte mit Connect-M365 Graph neu verbinden.$roleHint"
        }
        if ($null -ne $ConsentedScopes) {
            return & $done 'ConsentRequired' "Die Funktion kann nicht ausgeführt werden, weil dem aktuellen Access Token die delegierte Microsoft-Graph-Berechtigung $scopeText fehlt und dafür noch keine Zustimmung erteilt ist.$roleHint"
        }
        return & $done 'MissingGraphScope' "Die Funktion kann nicht ausgeführt werden, weil dem aktuellen Access Token die delegierte Microsoft-Graph-Berechtigung $scopeText fehlt.$roleHint"
    }

    if ($null -ne $CallerRoleIds) {
        $r.CallerRoles = @($CallerRoleIds | ForEach-Object { Get-M365RoleName $_ })
        if ($def.Roles) {
            $roleKeys = @($def.Roles | Where-Object { $CallerRoleIds -contains (Get-M365RoleId $_) })
            if (-not $roleKeys -and $LiveRoleIds -and @($def.Roles | Where-Object { $LiveRoleIds -contains (Get-M365RoleId $_) })) {
                $live = @($def.Roles | Where-Object { $LiveRoleIds -contains (Get-M365RoleId $_) })[0]
                return & $done 'FreshTokenRequired' "Die Rolle $($global:M365Roles[$live].Name) ist aktiv (z. B. per PIM aktiviert), steht aber noch nicht im verwendeten Access Token. Ein neues Token wird benötigt."
            }
            if (-not $roleKeys) {
                return & $done 'MissingDirectoryRole' ("Der Scope ist vorhanden, aber dem Benutzer fehlt eine passende aktive Entra-Rolle. Benötigt wird eine von: " + (($def.Roles | ForEach-Object { $global:M365Roles[$_].Name }) -join ', ') + '. (Bei PIM: Rolle aktivieren.)')
            }
            $r.AuthorizedByRole = $global:M365Roles[$roleKeys[0]].Name

            if ($def.Rule -and $null -ne $TargetRoleIds) {
                $r.TargetRoles = @($TargetRoleIds | ForEach-Object { Get-M365RoleName $_ })
                # Eingeschränkte Verwaltungseinheit: sperrt auch tenantweite Global-/Privileged-Admins aus
                if ($TargetRoleIds -contains 'restricted-au') {
                    return & $done 'TargetIsPrivileged' 'Der Zielbenutzer liegt in einer Verwaltungseinheit mit eingeschränkter Verwaltung. Ändern dürfen ihn nur Administratoren, die für diese Verwaltungseinheit zugewiesen sind – tenantweite Rollen (auch Global Administrator) reichen nicht.'
                }
                $rules = $global:M365TargetRules[$def.Rule]
                $mayAll = $false
                $manageable = @()
                foreach ($k in $roleKeys) {
                    if (-not $rules.Contains($k)) { continue }
                    if ($rules[$k] -eq '*') { $mayAll = $true } else { $manageable += $rules[$k] }
                }
                if (-not $mayAll) {
                    $manageableIds = @($manageable | ForEach-Object { Get-M365RoleId $_ })
                    $blocking = @($TargetRoleIds | Where-Object { $_ -and $global:M365DefaultUserRoleIds -notcontains $_ -and $manageableIds -notcontains $_ })
                    if ($blocking) {
                        $reasons = ($blocking | ForEach-Object { Get-M365RoleName $_ }) -join ', '
                        if ($blocking -contains 'restricted-au') {
                            return & $done 'TargetIsPrivileged' "Der Zielbenutzer ist geschützt ($reasons). Ändern dürfen ihn nur Administratoren, die für diese Verwaltungseinheit zugewiesen sind."
                        }
                        return & $done 'TargetIsPrivileged' ("Der Zielbenutzer ist ein privilegiertes Konto ($reasons). $($r.AuthorizedByRole) reicht für dieses Zielkonto nicht aus – dafür wird Privileged Authentication Administrator (oder Global Administrator) benötigt.")
                    }
                }
            }
        }
    }

    $by = "über Scope $($r.AuthorizedByScope)" + $(if ($r.AuthorizedByRole) { " und Rolle $($r.AuthorizedByRole)" } else { '' })
    return & $done 'Allowed' "Erlaubt ($by)."
}

# Preflight mit echten Daten aus Token und Graph.
function Test-M365Operation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Operation, [string]$TargetUser)
    $info = Get-M365GraphTokenInfo
    $consented = $null
    if ($info -and -not (@($global:M365Permissions[$Operation].Accept | Where-Object { @($info.Scopes) -contains $_ }))) {
        $consented = Get-M365ConsentedGraphScopes
    }
    $callerRoles = if ($info) { Get-M365CallerRoleIds $info } else { $null }
    # Fehlt die nötige Rolle im Token, live nachsehen – sonst bliebe man nach einer PIM-Aktivierung "read only"
    $liveRoles = $null
    $needed = $global:M365Permissions[$Operation].Roles
    if ($info -and $needed -and $null -ne $callerRoles -and -not @($needed | Where-Object { $callerRoles -contains (Get-M365RoleId $_) })) {
        $liveRoles = Get-M365LiveRoleIds
    }
    $targetRoles = if ($TargetUser -and $global:M365Permissions[$Operation].Rule) { Get-M365TargetRoleIds $TargetUser } else { $null }
    Get-M365OperationStatus -Operation $Operation -Token $info -ConsentedScopes $consented -CallerRoleIds $callerRoles -LiveRoleIds $liveRoles `
        -TargetRoleIds $targetRoles -TargetUser $TargetUser -EscalationSupported (Test-M365ScopeEscalation $info)
}

# ------------------------------------------------------------------ Fehlerdiagnose
function Resolve-M365GraphError {
    param([Parameter(Mandatory)]$ErrorRecord, [string]$Operation, [string]$TargetUser, [string]$Endpoint)
    $ex = $ErrorRecord.Exception
    $text = "$($ex.Message)`n$($ErrorRecord.ErrorDetails.Message)"
    $resp = $null
    foreach ($candidate in @($ex.Response, $ex.InnerException.Response)) { if ($candidate) { $resp = $candidate; break } }

    $status = $null
    if ($resp -and $resp.StatusCode) { $status = [int]$resp.StatusCode }
    elseif ($text -match '(?i)(?:Status(?:Code)?|HTTP)\W{0,3}(\d{3})') { $status = [int]$Matches[1] }

    $header = {
        param($name)
        try { if ($resp -and $resp.Headers) { $v = $null; if ($resp.Headers.TryGetValues($name, [ref]$v)) { return @($v)[0] } } } catch { }
        if ($text -match ('(?i)' + [regex]::Escape($name) + '"?\s*[:=]\s*"?([0-9a-f-]{36})')) { return $Matches[1] }
        return $null
    }
    $code = if ($text -match '"code"\s*:\s*"([^"]+)"') { $Matches[1] } elseif ($text -match '(?i)\bCode:\s*(\S+)') { $Matches[1] } else { $null }
    $message = if ($text -match '"message"\s*:\s*"([^"]+)"') { $Matches[1] } else { ($ex.Message -split "`r?`n")[0] }
    $wwwAuth = try { if ($resp -and $resp.Headers -and $resp.Headers.WwwAuthenticate) { "$($resp.Headers.WwwAuthenticate)" } } catch { $null }
    $claims = ("$wwwAuth" -match 'claims=') -or ($text -match '(?i)insufficient_claims|InteractionRequired|claims challenge|"claims"')
    $uri = try { if ($resp -and $resp.RequestMessage) { "$($resp.RequestMessage.Method) $($resp.RequestMessage.RequestUri)" } } catch { $null }

    $notConnected = $text -match '(?i)Authentication needed|call Connect-MgGraph'
    $kind = if ($claims) { 'ConditionalAccessOrClaimsChallenge' }
            elseif ($status -eq 401 -or $notConnected) { 'FreshTokenRequired' }
            elseif ($status -eq 403) { 'ForbiddenByGraph' }
            else { 'UnknownGraphError' }

    $info = Get-M365GraphTokenInfo
    $def = if ($Operation) { $global:M365Permissions[$Operation] } else { $null }
    $relevant = if ($def -and $info) { @($info.Scopes | Where-Object { $def.Accept -contains $_ }) } else { @() }

    $hint = switch ($kind) {
        'ConditionalAccessOrClaimsChallenge' { 'Conditional Access verlangt eine erneute bzw. stärkere Anmeldung (Claims Challenge). Bitte "Neu authentifizieren" wählen.' }
        'FreshTokenRequired' {
            if ($notConnected -and -not $status) { 'Microsoft Graph ist in dieser Sitzung nicht verbunden. Bitte verbinden (Connect-M365 Graph).' }
            else { 'Graph hat das Token abgelehnt (401) – abgelaufen oder widerrufen. Bitte neu authentifizieren.' }
        }
        'ForbiddenByGraph' {
            if ($def -and -not $relevant) { "Zugriff verweigert (403): Dem Token fehlt $($def.Least -join ', ')." }
            else { 'Zugriff verweigert (403): Scope ist vorhanden – meist fehlt die passende aktive Entra-Rolle oder das Zielkonto ist privilegiert (dann wird Privileged Authentication Administrator benötigt).' }
        }
        default { 'Unerwarteter Fehler von Microsoft Graph.' }
    }

    [pscustomobject][ordered]@{
        Status          = $kind
        Hint            = $hint
        HttpStatus      = $status
        GraphCode       = $code
        GraphMessage    = $message
        RequestId       = & $header 'request-id'
        ClientRequestId = & $header 'client-request-id'
        CorrelationId   = & $header 'x-ms-correlation-id'
        RequiredScopes  = if ($def) { $def.Least } else { @() }
        TokenScopes     = $relevant
        Tenant          = if ($info) { $info.TenantId } else { $null }
        ClientId        = if ($info) { $info.ClientId } else { $null }
        TargetUser      = $TargetUser
        Endpoint        = if ($uri) { $uri } elseif ($Endpoint) { $Endpoint } elseif ($def) { $def.Endpoint } else { $null }
    }
}

function Write-M365GraphDiagnostics($Diag) {
    Write-Host "  ✗ $($Diag.Hint)" -ForegroundColor Red
    $fields = 'HttpStatus', 'GraphCode', 'GraphMessage', 'RequestId', 'ClientRequestId', 'CorrelationId', 'Endpoint', 'TargetUser', 'Tenant', 'ClientId'
    foreach ($f in $fields) { if ($Diag.$f) { Write-Host ("    {0,-16} {1}" -f $f, $Diag.$f) -ForegroundColor DarkGray } }
    if ($Diag.RequiredScopes) { Write-Host ("    {0,-16} {1}" -f 'Benötigt', ($Diag.RequiredScopes -join ', ')) -ForegroundColor DarkGray }
    Write-Host ("    {0,-16} {1}" -f 'Im Token', $(if ($Diag.TokenScopes) { $Diag.TokenScopes -join ', ' } else { '–' })) -ForegroundColor DarkGray
    # Für das App-Protokoll (ohne Tokens)
    if (Get-Command Send-M365Host -ErrorAction SilentlyContinue) {
        Send-M365Host ("log|Graph {0} {1} {2}: {3} req={4} client-req={5} ziel={6} endpunkt={7}" -f $Diag.Status, $Diag.HttpStatus, $Diag.GraphCode, $Diag.GraphMessage, $Diag.RequestId, $Diag.ClientRequestId, $Diag.TargetUser, $Diag.Endpoint)
    }
}

function Get-M365LastGraphError {
    <# .SYNOPSIS Analysiert den letzten Fehler wie einen Graph-Fehler (HTTP-Status, Codes, request-id …). #>
    param([string]$Operation)
    if (-not $global:Error.Count) { Write-M365 'Kein Fehler vorhanden.' DarkGray; return }
    $diag = Resolve-M365GraphError -ErrorRecord $global:Error[0] -Operation $Operation
    Write-M365GraphDiagnostics $diag
    $diag
}