# M365 Manager · Hintergrund-PowerShell für den Exchange-RBAC-Bereich.
# Läuft unsichtbar, nutzt dieselbe Browser-Anmeldung wie das Terminal (Kanal M365M_PIPE) und beantwortet Anfragen.
# Protokoll: eine JSON-Zeile pro Anfrage auf stdin ({ id, op, args } bzw. { id, op = 'run', script }),
# Antwort als eine Zeile "<RS>M365RBAC {json}" auf stdout. Alles andere auf stdout wird ignoriert.

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
$script:Out = [Console]::Out
$script:Marker = [char]0x1e + 'M365RBAC '

# Gemeinsame Funktionen (Token über die App, Connect-M365 …) – ohne Begrüßung und ohne Terminal-Hooks
. (Join-Path $PSScriptRoot 'bootstrap.ps1') *> $null
$ExecutionContext.InvokeCommand.PreCommandLookupAction = $null
$ExecutionContext.InvokeCommand.CommandNotFoundAction = $null
$global:M365.AutoConnect = $false

# ------------------------------------------------------------------ Schutz der Entra-/Graph-Berechtigungen
# 1. Keine Ersatz-Anmeldung über das Modul (WAM/Windows-Konto) – nur die Browser-Anmeldung des Profils.
#    So kann sich hier nie ein anderes Konto anmelden und nirgends eine Zustimmung entstehen.
function Connect-M365Classic([string]$Svc, [string[]]$Scopes) {
    throw "Die Browser-Anmeldung des Profils konnte für $Svc nicht übernommen werden. Der RBAC-Bereich meldet sich bewusst nicht anders an – bitte im Terminal 'Connect-M365 $Svc' prüfen."
}
# 2. Graph wird nur mit den Profil-Berechtigungen und nur lesend verwendet. Änderungen in Entra laufen über das Entra-Portal.
$script:GraphGuard = '(?i)(\b(Connect-MgGraph|Connect-M365|Request-M365GraphScope|Invoke-M365Graph\w*)\b|\b(' +
    (@(Get-Verb | ForEach-Object Verb) -join '|') + ')-Mg[A-Za-z]\w*|graph\.microsoft\.com|\s-Scopes\b)'
function Test-RbacGraphGuard([string]$Script) {
    $m = [regex]::Match($Script, $script:GraphGuard)
    if ($m.Success) {
        throw "Im RBAC-Bereich werden keine Microsoft-Graph-/Entra-Befehle ausgeführt (gefunden: '$($m.Value.Trim())'). Der Bereich ändert nur Exchange – Entra-Berechtigungen bitte im Entra-Portal ändern."
    }
}

function Send-RbacReply([hashtable]$Reply) {
    $json = ConvertTo-Json $Reply -Depth 8 -Compress
    $script:Out.WriteLine($script:Marker + $json)
    $script:Out.Flush()
}

function Use-RbacService([string]$Service) {
    if ($global:M365.State[$Service] -eq 'connected') { return }
    $null = Connect-M365 $Service -Quiet *>&1
    if ($global:M365.State[$Service] -ne 'connected') {
        throw "Verbindung zu $Service fehlgeschlagen. Details im Protokoll; ggf. im Terminal 'Connect-M365 $Service' ausführen."
    }
}

function Join-RbacValue($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) { return (@($Value | ForEach-Object { "$_" }) -join ', ') }
    return "$Value"
}

function Get-RbacDate($Value) { if ($Value) { try { ([datetime]$Value).ToString('yyyy-MM-dd HH:mm') } catch { "$Value" } } else { '' } }

# ------------------------------------------------------------------ Lesen

$script:Ops = @{}

$script:Ops.connect = {
    Use-RbacService Exchange
    $org = Get-OrganizationConfig
    @{ organization = "$($org.DisplayName)"; tenant = $global:M365.Tenant; upn = $global:M365.Upn }
}

$script:Ops.roleGroups = {
    Use-RbacService Exchange
    ,@(Get-RoleGroup -ResultSize Unlimited | ForEach-Object {
        @{
            name = "$($_.Name)"; displayName = "$($_.DisplayName)"; description = "$($_.Description)"
            members = @($_.Members).Count; roles = @(@($_.Roles) | ForEach-Object { "$_" })
            type = "$($_.RoleGroupType)"; writeScope = "$($_.CustomRecipientWriteScope)"
            builtIn = [bool]($_.Capabilities -or $_.Description -match '^(Members of this|This role group|Membership in this)')
            created = Get-RbacDate $_.WhenCreated
        }
    })
}

$script:Ops.roleGroupMembers = {
    param($a)
    Use-RbacService Exchange
    ,@(Get-RoleGroupMember -Identity $a.identity -ResultSize Unlimited | ForEach-Object {
        @{ name = "$($_.Name)"; displayName = "$($_.DisplayName)"; type = "$($_.RecipientTypeDetails)"; smtp = "$($_.PrimarySmtpAddress)"; identity = "$($_.Identity)" }
    })
}

$script:Ops.roles = {
    Use-RbacService Exchange
    ,@(Get-ManagementRole | ForEach-Object {
        $custom = -not $_.IsRootRole -and "$($_.Parent)" -ne ''
        @{
            name = "$($_.Name)"; type = "$($_.RoleType)"; parent = "$($_.Parent)"; description = "$($_.Description)"
            custom = [bool]$custom; endUser = [bool]$_.IsEndUserRole; app = "$($_.Name)" -like 'Application *'
        }
    })
}

$script:Ops.roleEntries = {
    param($a)
    Use-RbacService Exchange
    ,@(Get-ManagementRoleEntry -Identity ("$($a.role)\*") | ForEach-Object {
        @{ name = "$($_.Name)"; parameters = @(@($_.Parameters) | ForEach-Object { "$_" }) }
    } | Sort-Object { $_.name })
}

$script:Ops.assignments = {
    Use-RbacService Exchange
    ,@(Get-ManagementRoleAssignment -GetEffectiveUsers:$false | ForEach-Object {
        @{
            name = "$($_.Name)"; role = "$($_.Role)"; assignee = "$($_.RoleAssigneeName)"; assigneeType = "$($_.RoleAssigneeType)"
            writeScope = "$($_.RecipientWriteScope)"; customWriteScope = "$($_.CustomRecipientWriteScope)"
            resourceScope = "$($_.CustomResourceScope)"; configScope = "$($_.ConfigWriteScope)"
            readScope = "$($_.RecipientReadScope)"; enabled = [bool]$_.Enabled; delegating = "$($_.RoleAssignmentDelegationType)"
            created = Get-RbacDate $_.WhenCreated; identity = "$($_.Identity)"
        }
    })
}

$script:Ops.scopes = {
    Use-RbacService Exchange
    ,@(Get-ManagementScope | ForEach-Object {
        @{
            name = "$($_.Name)"; type = "$($_.ScopeRestrictionType)"; root = "$($_.RecipientRoot)"
            filter = Join-RbacValue $_.RecipientFilter; exclusive = [bool]$_.Exclusive; isDefault = [bool]$_.IsDefault
            created = Get-RbacDate $_.WhenCreated
        }
    })
}

$script:Ops.previewFilter = {
    param($a)
    Use-RbacService Exchange
    $max = 500
    $items = @(Get-Recipient -RecipientPreviewFilter $a.filter -ResultSize ($max + 1) | ForEach-Object {
        @{ name = "$($_.DisplayName)"; smtp = "$($_.PrimarySmtpAddress)"; type = "$($_.RecipientTypeDetails)" }
    })
    @{ truncated = $items.Count -gt $max; items = @($items | Select-Object -First $max) }
}

$script:Ops.findGroups = {
    param($a)
    Use-RbacService Exchange
    $text = "$($a.text)".Replace("'", "''")
    ,@(Get-Group -Filter "DisplayName -like '*$text*' -or Name -like '*$text*'" -ResultSize 50 | ForEach-Object {
        @{
            name = "$($_.Name)"; displayName = "$($_.DisplayName)"; dn = "$($_.DistinguishedName)"; type = "$($_.RecipientTypeDetails)"
            smtp = "$($_.WindowsEmailAddress)"; members = @($_.Members).Count; id = "$($_.ExternalDirectoryObjectId)"
        }
    })
}

$script:Ops.findRecipients = {
    param($a)
    Use-RbacService Exchange
    $text = "$($a.text)".Replace("'", "''")
    ,@(Get-Recipient -Filter "DisplayName -like '*$text*' -or PrimarySmtpAddress -like '*$text*' -or Alias -like '*$text*'" -ResultSize 50 | ForEach-Object {
        @{ name = "$($_.DisplayName)"; smtp = "$($_.PrimarySmtpAddress)"; type = "$($_.RecipientTypeDetails)"; identity = "$($_.Identity)" }
    })
}

$script:Ops.userRights = {
    param($a)
    Use-RbacService Exchange
    $user = Get-User -Identity $a.user
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($r in Get-ManagementRoleAssignment -RoleAssignee $user.Identity -GetEffectiveUsers:$false) {
        $rows.Add(@{ role = "$($r.Role)"; via = 'direkt'; scope = "$(if ($r.CustomRecipientWriteScope) { $r.CustomRecipientWriteScope } else { $r.RecipientWriteScope })"; assignment = "$($r.Name)" })
    }
    foreach ($g in Get-RoleGroup -ResultSize Unlimited) {
        $isMember = @(Get-RoleGroupMember -Identity $g.Identity -ResultSize Unlimited | Where-Object { "$($_.ExternalDirectoryObjectId)" -eq "$($user.ExternalDirectoryObjectId)" -or "$($_.Identity)" -eq "$($user.Identity)" }).Count -gt 0
        if (-not $isMember) { continue }
        foreach ($r in Get-ManagementRoleAssignment -RoleAssignee $g.Identity -Delegating:$false -GetEffectiveUsers:$false) {
            $rows.Add(@{ role = "$($r.Role)"; via = "Rollengruppe $($g.Name)"; scope = "$(if ($r.CustomRecipientWriteScope) { $r.CustomRecipientWriteScope } else { $r.RecipientWriteScope })"; assignment = "$($r.Name)" })
        }
    }
    @{ user = "$($user.DisplayName) <$($user.UserPrincipalName)>"; rows = @($rows) }
}

$script:Ops.commandLookup = {
    param($a)
    Use-RbacService Exchange
    ,@(Get-ManagementRole -Cmdlet $a.cmdlet | ForEach-Object {
        @{ name = "$($_.Name)"; type = "$($_.RoleType)"; custom = -not $_.IsRootRole -and "$($_.Parent)" -ne ''; description = "$($_.Description)" }
    })
}

# ------------------------------------------------------------------ Anwendungen (RBAC for Applications)

# Graph-Berechtigungen, die Exchange-Postfächer betreffen und sich per RBAC for Applications einschränken lassen
$script:MailboxPermissions = 'Mail.Read', 'Mail.ReadBasic', 'Mail.ReadBasic.All', 'Mail.ReadWrite', 'Mail.Send', 'MailboxSettings.Read', 'MailboxSettings.ReadWrite',
    'Calendars.Read', 'Calendars.ReadBasic', 'Calendars.ReadWrite', 'Contacts.Read', 'Contacts.ReadWrite', 'MailboxFolder.Read.All', 'MailboxFolder.ReadWrite.All',
    'MailboxItem.Read.All', 'MailboxItem.ImportExport.All', 'full_access_as_app', 'EWS.AccessAsApp', 'IMAP.AccessAsApp', 'POP.AccessAsApp', 'SMTP.SendAsApp'
$script:ResourceApps = @{ '00000003-0000-0000-c000-000000000000' = 'Microsoft Graph'; '00000002-0000-0ff1-ce00-000000000000' = 'Office 365 Exchange Online' }

function Get-RbacResourceRoles {
    if ($script:ResourceRoleCache) { return $script:ResourceRoleCache }
    $map = @{}
    foreach ($appId in $script:ResourceApps.Keys) {
        $sp = Invoke-M365GraphGet "v1.0/servicePrincipals(appId='$appId')?`$select=id,appId,displayName,appRoles"
        $map[$appId] = @{ id = $sp.id; name = $script:ResourceApps[$appId]; roles = @{} }
        foreach ($r in $sp.appRoles) { $map[$appId].roles["$($r.id)"] = "$($r.value)" }
    }
    $script:ResourceRoleCache = $map
    $map
}

# Zuweisung an eine App: Postfachrolle (Application …, Bereich = CustomResourceScope) oder Exchange-Verwaltungsrolle
# (z. B. per Exchange.ManageAsApp, Bereich = Schreibbereich). Leerer Bereich = ganze Organisation.
function ConvertTo-RbacAppAssignment($r) {
    $isApp = "$($r.Role)" -like 'Application *'
    $scope = if ($isApp) { "$($r.CustomResourceScope)" }
             elseif ($r.CustomRecipientWriteScope) { "$($r.CustomRecipientWriteScope)" }
             elseif ($r.RecipientAdministrativeUnitScope) { "$($r.RecipientAdministrativeUnitScope)" }
             elseif ($r.RecipientOrganizationalUnitScope) { "$($r.RecipientOrganizationalUnitScope)" }
             else { '' }
    @{ name = "$($r.Name)"; role = "$($r.Role)"; scope = $scope; enabled = [bool]$r.Enabled; app = $isApp }
}

$script:Ops.apps = {
    Use-RbacService Graph
    Use-RbacService Exchange
    $resources = Get-RbacResourceRoles
    $apps = @{}
    foreach ($res in $resources.Values) {
        $uri = "v1.0/servicePrincipals/$($res.id)/appRoleAssignedTo?`$top=999"
        while ($uri) {
            $page = Invoke-M365GraphGet $uri
            foreach ($g in $page.value) {
                $perm = $res.roles["$($g.appRoleId)"]
                if (-not $perm -or $perm -notin $script:MailboxPermissions) { continue }
                $key = "$($g.principalId)"
                if (-not $apps[$key]) { $apps[$key] = @{ objectId = $key; displayName = "$($g.principalDisplayName)"; grants = [System.Collections.Generic.List[object]]::new() } }
                $apps[$key].grants.Add(@{ permission = $perm; resource = $res.name; assignmentId = "$($g.id)"; resourceId = "$($res.id)" })
            }
            $uri = $page.'@odata.nextLink'
        }
    }
    # AppId und Exchange-Gegenstück (Service Principal in Exchange) ergänzen
    $exo = @{}
    foreach ($sp in Get-ServicePrincipal) { $exo["$($sp.AppId)"] = $sp }
    $assignments = @(Get-ManagementRoleAssignment -GetEffectiveUsers:$false | Where-Object { "$($_.RoleAssigneeType)" -eq 'ServicePrincipal' })
    $policies = @(try { Get-ApplicationAccessPolicy } catch { @() })
    foreach ($a in $apps.Values) {
        $sp = Invoke-M365GraphGet "v1.0/servicePrincipals/$($a.objectId)?`$select=appId,appOwnerOrganizationId,servicePrincipalType"
        $a.appId = "$($sp.appId)"
        $a.ownTenant = "$($sp.appOwnerOrganizationId)" -eq "$((Get-M365GraphTokenInfo).TenantId)"
        $e = $exo[$a.appId]
        $a.exoName = if ($e) { "$($e.DisplayName)" } else { '' }
        $a.exoIdentity = if ($e) { "$($e.Identity)" } else { '' }
        $a.rbac = @($assignments | Where-Object { $e -and ("$($_.RoleAssigneeName)" -eq "$($e.Name)" -or "$($_.RoleAssigneeName)" -eq "$($e.Identity)" -or "$($_.RoleAssignee)" -eq "$($e.Identity)") } | ForEach-Object { ConvertTo-RbacAppAssignment $_ })
        $a.policies = @($policies | Where-Object { "$($_.AppId)" -eq $a.appId } | ForEach-Object { @{ identity = "$($_.Identity)"; restriction = "$($_.AccessRight)"; scope = "$($_.ScopeName)" } })
        $a.grants = @($a.grants)
    }
    # Auch Apps, die nur noch per RBAC berechtigt sind (Entra-Rechte schon entfernt), anzeigen
    foreach ($e in $exo.Values) {
        if ($apps.Values | Where-Object { $_.appId -eq "$($e.AppId)" }) { continue }
        $rbac = @($assignments | Where-Object { "$($_.RoleAssigneeName)" -eq "$($e.Name)" -or "$($_.RoleAssigneeName)" -eq "$($e.Identity)" -or "$($_.RoleAssignee)" -eq "$($e.Identity)" })
        $apps["exo-$($e.AppId)"] = @{
            objectId = "$($e.ObjectId)"; appId = "$($e.AppId)"; displayName = "$($e.DisplayName)"; grants = @(); ownTenant = $true
            exoName = "$($e.DisplayName)"; exoIdentity = "$($e.Identity)"
            rbac = @($rbac | ForEach-Object { ConvertTo-RbacAppAssignment $_ })
            policies = @($policies | Where-Object { "$($_.AppId)" -eq "$($e.AppId)" } | ForEach-Object { @{ identity = "$($_.Identity)"; restriction = "$($_.AccessRight)"; scope = "$($_.ScopeName)" } })
        }
    }
    ,@($apps.Values | Sort-Object { $_.displayName })
}

$script:Ops.findEntraApps = {
    param($a)
    Use-RbacService Graph
    $text = "$($a.text)".Replace("'", "''")
    $filter = if ($text -match '^[0-9a-fA-F-]{36}$') { "appId eq '$text'" } else { "startswith(displayName,'$text')" }
    ,@((Invoke-M365GraphGet "v1.0/servicePrincipals?`$filter=$([uri]::EscapeDataString($filter))&`$select=id,appId,displayName,servicePrincipalType&`$top=25").value | ForEach-Object {
        @{ objectId = "$($_.id)"; appId = "$($_.appId)"; displayName = "$($_.displayName)"; type = "$($_.servicePrincipalType)" }
    })
}

$script:Ops.appRoles = {
    Use-RbacService Exchange
    ,@(Get-ManagementRole | Where-Object { "$($_.Name)" -like 'Application *' } | ForEach-Object { @{ name = "$($_.Name)"; description = "$($_.Description)" } } | Sort-Object { $_.name })
}

$script:Ops.testApp = {
    param($a)
    Use-RbacService Exchange
    ,@(Test-ServicePrincipalAuthorization -Identity $a.identity -Resource $a.resource | ForEach-Object {
        @{ role = "$($_.RoleName)"; permissions = Join-RbacValue $_.GrantedPermissions; scope = "$($_.AllowedResourceScope)"; scopeType = "$($_.ScopeType)"; inScope = [bool]$_.InScope }
    })
}

# ------------------------------------------------------------------ Ausführen (Befehl aus der Vorschau, genau so wie angezeigt)

$script:Ops.run = {
    param($a, $script)
    Test-RbacGraphGuard $script
    Use-RbacService Exchange
    $sb = [scriptblock]::Create($script)
    # Beim ersten Fehler anhalten (keine Folgebefehle auf halbem Stand) – die Ausgabe bis dahin trotzdem zurückgeben
    $lines = [System.Collections.Generic.List[object]]::new()
    try {
        & $sb *>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { throw $_ }
            elseif ($_ -is [System.Management.Automation.WarningRecord]) { $lines.Add("WARNUNG: $($_.Message)") }
            elseif ($_ -is [System.Management.Automation.InformationRecord]) { $lines.Add("$($_.MessageData)") }
            else { $lines.Add($_) }
        }
    }
    catch {
        $lines.Add("FEHLER: $($_.Exception.Message)")
        $lines.Add('Abgebrochen – folgende Befehle wurden nicht mehr ausgeführt.')
    }
    @{ output = ($lines | Out-String -Width 220).TrimEnd() }
}

# ------------------------------------------------------------------ Schleife

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    if (-not $line.Trim()) { continue }
    $req = $null
    try {
        $req = $line | ConvertFrom-Json
        $op = $script:Ops["$($req.op)"]
        if (-not $op) { throw "Unbekannte Anfrage: $($req.op)" }
        $data = & $op $req.args $req.script
        Send-RbacReply @{ id = $req.id; ok = $true; data = $data }
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException -and $_.Exception.InnerException.Message -notin $msg) { $msg += ' (' + $_.Exception.InnerException.Message + ')' }
        Send-RbacReply @{ id = $(if ($req) { $req.id } else { 0 }); ok = $false; error = $msg }
    }
}
