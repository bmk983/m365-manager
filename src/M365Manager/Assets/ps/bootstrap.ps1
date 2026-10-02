# ------------------------------------------------------------------------------
#  M365 Manager · Terminal-Bootstrap
#  Wird bei jedem Terminalstart in die globale Sitzung geladen.
#  Eigene Ergänzungen: <Datenordner>\custom.ps1 (wird am Ende geladen).
# ------------------------------------------------------------------------------

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
if ($PSStyle) { $PSStyle.OutputRendering = 'Host' }

if ($env:M365M_MODULES -and (Test-Path $env:M365M_MODULES)) {
    $env:PSModulePath = $env:M365M_MODULES + [IO.Path]::PathSeparator + $env:PSModulePath
}

$global:M365 = @{
    Profile     = $env:M365M_PROFILE
    Upn         = $env:M365M_UPN
    Tenant      = $env:M365M_TENANT
    SpTenant    = $env:M365M_SPTENANT
    PnPClientId = $env:M365M_PNPCLIENTID
    GraphScopes = @($env:M365M_GRAPHSCOPES -split '[\s,;]+' | Where-Object { $_ })
    State       = [ordered]@{ Graph = 'disconnected'; Exchange = 'disconnected'; Purview = 'disconnected'; Teams = 'disconnected'; SharePoint = 'disconnected' }
    Short       = @{ Graph = 'Graph'; Exchange = 'EXO'; Purview = 'Purview'; Teams = 'Teams'; SharePoint = 'SPO' }
    Tried       = @{}
    Busy        = $false
    AutoConnect = $true
    TokenMode   = $true
    Expiry      = @{}
    Verbs       = @(Get-Verb | ForEach-Object Verb)
}

$global:M365Patterns = @{
    # Diese Module sind lokal vorhanden, brauchen aber eine Verbindung -> vor dem Ausführen verbinden.
    Graph      = '^\w+-Mg\w+$'
    GraphSkip  = '^(Connect|Disconnect)-MgGraph$|-Mg(Context|Environment|GraphOption|RequestContext)$|^Find-MgGraph'
    Teams      = '^\w+-(Cs(?!v$)\w+|Team\w*)$'
    PnP        = '^\w+-PnP\w+$'
    PnPSkip    = '^(Connect|Disconnect)-PnPOnline$|^Register-PnP|PowerShellTelemetry'
    ExoStatic  = '^\w+-EXO\w+$'
    # Diese Cmdlets existieren erst nach dem Verbinden (Remote-Module) -> beim "Befehl nicht gefunden" verbinden.
    Purview    = '^\w+-(\w*Compliance\w*|Dlp\w*|Label|LabelPolicy|AutoSensitivityLabel\w*|RetentionEvent\w*|CaseHold\w*|eDiscovery\w*|ProtectionAlert|ActivityAlert|InformationBarrier\w*|Supervisory\w*|DataClassification\w*|SensitiveInformation\w*|FilePlan\w*|AdaptiveScope|InsiderRisk\w*)$'
    Exchange   = '^\w+-(\w*Mailbox\w*|Mail(User|Contact|Flow\w*|Detail\w*|TrafficPolicy\w*)|Recipient\w*|(Dynamic)?DistributionGroup\w*|UnifiedGroup\w*|Transport\w*|(Inbound|Outbound)Connector|AcceptedDomain|RemoteDomain|MessageTrac\w*|Calendar\w*|MobileDevice\w*|Quarantine\w*|Hosted\w*|Malware\w*|SafeLinks\w*|SafeAttachment\w*|AntiPhish\w*|Atp\w*|Dkim\w*|Organization(Config|Relationship)|SharingPolicy|RetentionPolicy\w*|Owa\w*|ManagementRole\w*|RoleGroup\w*|(Global)?AddressList|OfflineAddressBook|EmailAddressPolicy|Journal\w*|MoveRequest\w*|Migration\w*|InboxRule|(Unified|Admin)AuditLog\w*|Place|TenantAllowBlockList\w*|FocusedInbox|Clutter|ResourceConfig|User|Group|Contact|AuthenticationPolicy|ClientAccessRule|App|EOP\w*|PhishSim\w*|SecOps\w*|ReportSubmission\w*|HybridMailflow\w*|IntraOrganization\w*|EmailTenantSettings|ArcConfig)$'
}

# ------------------------------------------------------------------ Rückkanal zur App

function Open-M365Channel {
    if ($global:M365Pipe -and $global:M365Pipe.IsConnected) { return }
    $global:M365Pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $env:M365M_PIPE, [System.IO.Pipes.PipeDirection]::InOut)
    $global:M365Pipe.Connect(3000)
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $global:M365PipeWriter = [System.IO.StreamWriter]::new($global:M365Pipe, $utf8)
    $global:M365PipeWriter.AutoFlush = $true
    $global:M365PipeReader = [System.IO.StreamReader]::new($global:M365Pipe, $utf8)
    $global:M365PendingRead = $null
}

function Send-M365Host([string]$Message) {
    if (-not $env:M365M_PIPE) { return }
    try {
        Open-M365Channel
        $global:M365PipeWriter.WriteLine($Message)
    }
    catch {
        $global:M365Pipe = $null
    }
}

function Get-M365Token {
    <#
    .SYNOPSIS
        Holt ein Token aus der Browser-Anmeldung dieses Profils (ohne erneute Anmeldung / MFA, solange der Browser angemeldet ist).
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('Graph', 'Exchange', 'Purview', 'Teams', 'TeamsGraph', 'SharePoint')][string]$Service,
        [string[]]$ExtraScopes
    )
    if (-not $env:M365M_PIPE) { throw 'Kein Kanal zur App vorhanden.' }
    Open-M365Channel
    $id = [guid]::NewGuid().ToString('N')
    $global:M365PipeWriter.WriteLine("req|$id|token|$Service|$(($ExtraScopes -join ' ') -replace '\|', '')")

    while ($true) {
        # Lesen in kleinen Schritten, damit Strg+C wirkt. Eine offene Leseoperation wird wiederverwendet.
        if (-not $global:M365PendingRead) { $global:M365PendingRead = $global:M365PipeReader.ReadLineAsync() }
        while (-not $global:M365PendingRead.Wait(200)) { }
        $line = $global:M365PendingRead.Result
        $global:M365PendingRead = $null
        if ($null -eq $line) { $global:M365Pipe = $null; throw 'Kanal zur App wurde getrennt.' }

        $parts = $line.Split('|', 5)
        if ($parts[0] -ne 'res' -or $parts[1] -ne $id) { continue }
        if ($parts[2] -ne 'ok') { throw $parts[3] }
        return [pscustomobject]@{
            Token     = $parts[3]
            ExpiresOn = [DateTimeOffset]::FromUnixTimeSeconds([long]$parts[4])
        }
    }
}
function Set-M365State([string]$Service, [string]$State, [string]$Detail = '') {
    $global:M365.State[$Service] = $State
    Send-M365Host ('svc|{0}|{1}|{2}' -f $Service, $State, ($Detail -replace '[\r\n|]+', ' '))
}

function Write-M365([string]$Text, [string]$Color = 'Gray') {
    Write-Host "  $Text" -ForegroundColor $Color
}

# ------------------------------------------------------------------ Verbinden

function Connect-M365 {
    <#
    .SYNOPSIS
        Verbindet die Sitzung mit einem oder mehreren M365-Diensten, angemeldet als Profil-Admin.
        Standard: Die Anmeldung wird aus dem integrierten Browser übernommen (kein zweites MFA).
        -Classic nutzt stattdessen die normale Anmeldung des jeweiligen Moduls.
    .EXAMPLE
        Connect-M365 Graph
        Connect-M365 Exchange, Teams
        Connect-M365 All
        Connect-M365 Graph -Scopes 'Mail.Read'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('Graph', 'Exchange', 'Purview', 'Teams', 'SharePoint', 'All')]
        [string[]]$Service = 'All',
        [string[]]$Scopes,
        [switch]$Force,
        [switch]$Auto,
        [switch]$Classic,
        [switch]$Quiet
    )

    if ($Service -contains 'All') { $Service = @($global:M365.State.Keys) }
    $upn = $global:M365.Upn
    $tenant = $global:M365.Tenant
    $useToken = -not $Classic -and $global:M365.TokenMode -and $env:M365M_PIPE

    foreach ($svc in $Service) {
        if (-not $Auto) { $global:M365.Tried.Remove($svc) }
        if (-not $Force -and $global:M365.State[$svc] -eq 'connected') {
            Write-M365 "$svc ist bereits verbunden." DarkGray
            continue
        }

        $global:M365.Busy = $true
        Set-M365State $svc 'connecting'
        if (-not $Quiet) {
            if ($Auto) { Write-M365 "Befehl benötigt $svc → verbinde als $upn …" Cyan }
            else { Write-M365 "Verbinde $svc als $upn …" Cyan }
        }

        try {
            $detail = $upn
            $global:M365.Expiry.Remove($svc)
            $tokenOk = $false
            if ($useToken) {
                try {
                    $expires = Connect-M365WithToken $svc $Scopes
                    $global:M365.Expiry[$svc] = $expires
                    $tokenOk = $true
                    if ($svc -eq 'SharePoint') { $detail = "https://$($global:M365.SpTenant)-admin.sharepoint.com" }
                }
                catch {
                    Write-M365 "Übernahme der Browser-Anmeldung nicht möglich: $($_.Exception.Message)" DarkYellow
                    Write-M365 'Nutze stattdessen die normale Anmeldung des Moduls …' DarkGray
                }
            }
            if (-not $tokenOk) { $detail = Connect-M365Classic $svc $Scopes }

            Set-M365State $svc 'connected' $detail
            if ($Quiet) { Write-M365 "↻ $svc-Anmeldung erneuert." DarkGray }
            else { Write-M365 "✓ $svc verbunden." Green }
        }
        catch {
            $msg = $_.Exception.Message
            Set-M365State $svc 'error' $msg
            if ($Auto) { $global:M365.Tried[$svc] = $true }
            Write-M365 "✗ ${svc}: $msg" Red
            if ($Auto) { Write-M365 "Automatisches Verbinden für $svc pausiert. Erneut: Connect-M365 $svc" DarkGray }
        }
        finally {
            $global:M365.Busy = $false
        }
    }
}

# Verbindet per Token aus der Browser-Sitzung. Gibt den Ablaufzeitpunkt zurück.
function Connect-M365WithToken([string]$Svc, [string[]]$Scopes) {
    $tenant = $global:M365.Tenant
    switch ($Svc) {
        'Graph' {
            $t = Get-M365Token Graph -ExtraScopes $Scopes
            Connect-MgGraph -AccessToken (ConvertTo-SecureString $t.Token -AsPlainText -Force) -NoWelcome -ErrorAction Stop
            return $t.ExpiresOn
        }
        'Exchange' {
            $t = Get-M365Token Exchange
            $p = @{ AccessToken = $t.Token; Organization = $tenant; ShowBanner = $false; ErrorAction = 'Stop' }
            Connect-ExchangeOnline @p
            return $t.ExpiresOn
        }
        'Purview' {
            $cmd = Get-Command Connect-IPPSSession
            if (-not $cmd.Parameters.ContainsKey('AccessToken')) { throw 'Diese Version von Connect-IPPSSession kann keine Tokens übernehmen.' }
            $t = Get-M365Token Purview
            $p = @{ AccessToken = $t.Token; Organization = $tenant; ErrorAction = 'Stop' }
            if ($cmd.Parameters.ContainsKey('ShowBanner')) { $p.ShowBanner = $false }
            Connect-IPPSSession @p
            return $t.ExpiresOn
        }
        'Teams' {
            $g = Get-M365Token TeamsGraph
            $t = Get-M365Token Teams
            Connect-MicrosoftTeams -AccessTokens @($g.Token, $t.Token) -ErrorAction Stop | Out-Null
            return @($g.ExpiresOn, $t.ExpiresOn) | Sort-Object | Select-Object -First 1
        }
        'SharePoint' {
            Initialize-M365SharePoint
            $t = Get-M365Token SharePoint
            Connect-PnPOnline -Url "https://$($global:M365.SpTenant)-admin.sharepoint.com" -AccessToken $t.Token -ErrorAction Stop
            return $t.ExpiresOn
        }
    }
}

# Normale Anmeldung des jeweiligen Moduls (Fallback). Gibt das Detail für den Status zurück.
function Connect-M365Classic([string]$Svc, [string[]]$Scopes) {
    $upn = $global:M365.Upn
    $tenant = $global:M365.Tenant
    switch ($Svc) {
        'Graph' {
            $p = @{ NoWelcome = $true; ContextScope = 'Process'; ErrorAction = 'Stop' }
            $sc = if ($Scopes) { @($global:M365.GraphScopes) + $Scopes | Select-Object -Unique } else { $global:M365.GraphScopes }
            if ($sc) { $p.Scopes = $sc }
            if ($tenant) { $p.TenantId = $tenant }
            try { Connect-MgGraph @p }
            catch {
                if ($_.Exception.Message -notmatch 'WAM|broker|window handle') { throw }
                Set-MgGraphOption -DisableLoginByWAM $true
                Connect-MgGraph @p
            }
            $ctx = Get-MgContext
            if (-not $ctx) { throw 'Keine Graph-Verbindung.' }
            return $ctx.Account
        }
        'Exchange' {
            $p = @{ ShowBanner = $false; ErrorAction = 'Stop' }
            if ($upn) { $p.UserPrincipalName = $upn }
            Connect-ExchangeOnline @p
            return $upn
        }
        'Purview' {
            $cmd = Get-Command Connect-IPPSSession
            $p = @{ ErrorAction = 'Stop' }
            if ($upn) { $p.UserPrincipalName = $upn }
            if ($cmd.Parameters.ContainsKey('ShowBanner')) { $p.ShowBanner = $false }
            Connect-IPPSSession @p
            return $upn
        }
        'Teams' {
            $p = @{ ErrorAction = 'Stop' }
            if ($upn) { $p.AccountId = $upn }
            $r = Connect-MicrosoftTeams @p
            if ($r.Account) { return "$($r.Account)" }
            return $upn
        }
        'SharePoint' {
            Initialize-M365SharePoint
            $url = "https://$($global:M365.SpTenant)-admin.sharepoint.com"
            Connect-PnPOnline -Url $url -Interactive -ClientId $global:M365.PnPClientId -ErrorAction Stop
            return $url
        }
    }
}
function Disconnect-M365 {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateSet('Graph', 'Exchange', 'Purview', 'Teams', 'SharePoint', 'All')]
        [string[]]$Service = 'All'
    )
    if ($Service -contains 'All') { $Service = @($global:M365.State.Keys) }
    $global:M365.Busy = $true
    try {
        foreach ($svc in $Service) {
            try {
                switch ($svc) {
                    'Graph'      { if (Get-Module Microsoft.Graph.Authentication) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } }
                    'Exchange'   { if (Get-Module ExchangeOnlineManagement) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } }
                    'Purview'    { if (Get-Module ExchangeOnlineManagement) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } }
                    'Teams'      { if (Get-Module MicrosoftTeams) { Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue | Out-Null } }
                    'SharePoint' { if (Get-Module PnP.PowerShell) { Disconnect-PnPOnline -ErrorAction SilentlyContinue } }
                }
            }
            catch { }
            $global:M365.Tried.Remove($svc)
            $global:M365.Expiry.Remove($svc)
            Set-M365State $svc 'disconnected'
            Write-M365 "$svc getrennt." DarkGray
        }
        # Exchange und Purview teilen sich das Modul – Trennen betrifft beide.
        if ($Service -contains 'Exchange' -or $Service -contains 'Purview') {
            foreach ($s in 'Exchange', 'Purview') { if ($global:M365.State[$s] -ne 'disconnected') { Set-M365State $s 'disconnected' } }
        }
    }
    finally { $global:M365.Busy = $false }
}

# ------------------------------------------------------------------ SharePoint / PnP

function Get-M365SharePointTenant {
    if ($global:M365.SpTenant) { return $global:M365.SpTenant }
    $t = $null
    if ($global:M365.Tenant -match '^([^.]+)\.onmicrosoft\.com$') { $t = $Matches[1] }
    elseif ($global:M365.State.Graph -eq 'connected') {
        try {
            $initial = (Get-MgOrganization -ErrorAction Stop).VerifiedDomains | Where-Object IsInitial | Select-Object -First 1
            if ($initial) { $t = $initial.Name -replace '\.onmicrosoft\.com$', '' }
        }
        catch { }
    }
    if (-not $t) {
        $t = (Read-Host '  SharePoint-Tenantname (z. B. "contoso" für contoso-admin.sharepoint.com)').Trim()
    }
    if ($t) {
        $global:M365.SpTenant = $t
        Send-M365Host "set|SharePointTenant|$t"
    }
    $t
}

function Register-M365PnPApp {
    <#
    .SYNOPSIS
        Legt im Tenant eine eigene App-Registrierung für PnP.PowerShell an.
        Nur delegierte Berechtigungen, kein Client-Secret, kein Zertifikat – Aktionen laufen immer im Namen des angemeldeten Admins.
    #>
    $sp = Get-M365SharePointTenant
    $tenant = if ($sp) { "$sp.onmicrosoft.com" } else { $global:M365.Tenant }
    $cmd = Get-Command Register-PnPEntraIDAppForInteractiveLogin -ErrorAction Stop

    $p = @{ ApplicationName = "M365 Manager (PnP) - $($global:M365.Profile)"; Tenant = $tenant; ErrorAction = 'Stop' }
    if ($cmd.Parameters.ContainsKey('Interactive')) { $p.Interactive = $true }
    if ($cmd.Parameters.ContainsKey('SharePointDelegatePermissions')) { $p.SharePointDelegatePermissions = 'AllSites.FullControl', 'TermStore.ReadWrite.All', 'User.ReadWrite.All' }
    if ($cmd.Parameters.ContainsKey('GraphDelegatePermissions')) { $p.GraphDelegatePermissions = 'Group.ReadWrite.All', 'User.Read.All', 'Sites.FullControl.All' }

    Write-M365 "Registriere App '$($p.ApplicationName)' in $tenant (nur delegierte Rechte) …" Cyan
    Write-M365 'Es folgen eine Anmeldung und die Zustimmung (Consent) im Browser.' DarkGray
    $result = Register-PnPEntraIDAppForInteractiveLogin @p

    $id = $null
    foreach ($prop in $result.PSObject.Properties) {
        if ("$($prop.Value)" -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { $id = "$($prop.Value)"; break }
    }
    if (-not $id) { throw 'ClientId der neuen App konnte nicht ermittelt werden.' }

    $global:M365.PnPClientId = $id
    Send-M365Host "set|PnPClientId|$id"
    Write-M365 "✓ App angelegt, ClientId $id im Profil gespeichert." Green
    Write-M365 'Hinweis: Neue Apps brauchen in Entra manchmal 1-2 Minuten, bis die Anmeldung klappt.' DarkGray
    $id
}

# Stellt sicher, dass SharePoint-Tenantname und PnP-App bekannt sind.
function Initialize-M365SharePoint {
    $t = Get-M365SharePointTenant
    if (-not $t) { throw 'Kein SharePoint-Tenantname angegeben.' }

    if (-not $global:M365.PnPClientId) {
        Write-M365 'PnP.PowerShell braucht pro Tenant eine eigene App-Registrierung (nur delegierte Rechte, ohne Secret).' Yellow
        $answer = Read-Host '  Jetzt im Tenant anlegen? [J/n]'
        if ($answer -and $answer -notmatch '^(j|y)') {
            throw 'Abgebrochen. Später: Register-M365PnPApp oder ClientId im Profil eintragen.'
        }
        Register-M365PnPApp | Out-Null
    }
}
# ------------------------------------------------------------------ Status & Hilfe

function Get-M365Status {
    foreach ($k in $global:M365.State.Keys) {
        [pscustomobject]@{ Dienst = $k; Status = $global:M365.State[$k] }
    }
}

function Set-M365AutoConnect([bool]$Enabled = $true) {
    $global:M365.AutoConnect = $Enabled
    $global:M365.Tried.Clear()
    Write-M365 ("Automatisches Verbinden ist jetzt " + $(if ($Enabled) { 'an.' } else { 'aus.' })) Cyan
}

function Install-M365Module {
    <# .SYNOPSIS Lädt ein zusätzliches Modul portabel in den Datenordner. #>
    param([Parameter(Mandatory)][string[]]$Name)
    Save-PSResource -Name $Name -Path $env:M365M_MODULES -Repository PSGallery -TrustRepository
    Write-M365 "✓ Installiert: $($Name -join ', ')" Green
}

function Get-M365Help {
    $c = "`e[36m"; $r = "`e[0m"; $d = "`e[90m"
    Write-Host ''
    Write-Host "  ${c}Automatisch${r}  Dienste verbinden sich beim ersten passenden Befehl:"
    Write-Host "  ${d}Graph      ${r}Get-MgUser, Get-MgGroup, Get-MgDevice, Get-MgSecurityIncident …"
    Write-Host "  ${d}Exchange   ${r}Get-Mailbox, Get-EXOMailbox, Get-DistributionGroup, Get-MessageTraceV2 …"
    Write-Host "  ${d}Purview    ${r}Get-DlpCompliancePolicy, Get-Label, Get-ComplianceSearch …"
    Write-Host "  ${d}Teams      ${r}Get-Team, Get-CsOnlineUser, Get-CsTeamsMeetingPolicy …"
    Write-Host "  ${d}SharePoint ${r}Get-PnPTenantSite, Get-PnPTenant, Get-PnPList …"
    Write-Host ''
    Write-Host "  ${c}Befehle${r}"
    Write-Host "  Connect-M365 [Graph|Exchange|Purview|Teams|SharePoint|All]   manuell verbinden"
    Write-Host "  Connect-M365 Graph -Scopes Mail.Read                        zusätzliche Graph-Berechtigung"
    Write-Host "  Connect-M365 Exchange -Classic                              normale Modul-Anmeldung statt Browser-Übernahme"
    Write-Host "  Disconnect-M365 [Dienst|All]                                trennen"
    Write-Host "  Get-M365Status                                               Verbindungsstatus"
    Write-Host "  Set-M365AutoConnect `$false                                  Auto-Verbinden aus"
    Write-Host "  Register-M365PnPApp                                         PnP-App im Tenant anlegen"
    Write-Host "  Install-M365Module <Name>                                   weiteres Modul portabel laden"
    Write-Host ''
}

# ------------------------------------------------------------------ Auto-Connect

function Resolve-M365Service([string]$Name, [switch]$NotFound) {
    $p = $global:M365Patterns
    if (-not $NotFound) {
        if ($Name -match $p.Graph -and $Name -notmatch $p.GraphSkip) { return 'Graph' }
        if ($Name -match $p.PnP -and $Name -notmatch $p.PnPSkip) { return 'SharePoint' }
        if ($Name -match $p.Teams) { return 'Teams' }
        if ($Name -match $p.ExoStatic) { return 'Exchange' }
        return $null
    }
    if ($Name -notmatch '^(\w+)-\w+$' -or $global:M365.Verbs -notcontains $Matches[1]) { return $null }
    if ($Name -match $p.Purview) { return 'Purview' }
    if ($Name -match $p.Exchange) { return 'Exchange' }
    $null
}

# Erneuert eine per Token übernommene Verbindung still, kurz bevor sie abläuft.
function Update-M365Connection([string]$Name) {
    $svc = Resolve-M365Service $Name
    if (-not $svc) { $svc = Resolve-M365Service $Name -NotFound }
    if (-not $svc -or $global:M365.State[$svc] -ne 'connected') { return $svc }
    $exp = $global:M365.Expiry[$svc]
    if ($exp -and $exp -lt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        Connect-M365 -Service $svc -Force -Auto -Quiet
    }
    $svc
}

$ExecutionContext.InvokeCommand.PreCommandLookupAction = {
    param([string]$CommandName, [System.Management.Automation.CommandLookupEventArgs]$EventArgs)
    if ($global:M365.Busy -or -not $global:M365.AutoConnect) { return }
    if ($EventArgs.CommandOrigin -ne 'Runspace') { return }
    if ($CommandName -notmatch '^\w+-\w+$') { return }
    Update-M365Connection $CommandName | Out-Null
    $svc = Resolve-M365Service $CommandName
    if (-not $svc -or $global:M365.State[$svc] -eq 'connected' -or $global:M365.Tried[$svc]) { return }
    Connect-M365 -Service $svc -Auto
}
$ExecutionContext.InvokeCommand.CommandNotFoundAction = {
    param([string]$CommandName, [System.Management.Automation.CommandLookupEventArgs]$EventArgs)
    if ($global:M365.Busy -or -not $global:M365.AutoConnect) { return }
    $svc = Resolve-M365Service $CommandName -NotFound
    if (-not $svc -or $global:M365.State[$svc] -eq 'connected' -or $global:M365.Tried[$svc]) { return }
    Connect-M365 -Service $svc -Auto
    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($cmd) {
        $EventArgs.Command = $cmd
        $EventArgs.StopSearch = $true
    }
}

# Hält den Status aktuell, auch wenn manuell Connect-MgGraph / Connect-ExchangeOnline … benutzt wurde.
function Sync-M365State {
    if ($global:M365.Busy) { return }
    try {
        if (Get-Module Microsoft.Graph.Authentication) {
            $ctx = Get-MgContext
            $want = if ($ctx) { 'connected' } else { 'disconnected' }
            if ($global:M365.State.Graph -ne 'error' -and $global:M365.State.Graph -ne $want) { Set-M365State Graph $want "$($ctx.Account)" }
        }
        if (Get-Module ExchangeOnlineManagement) {
            $conns = @(Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object State -eq 'Connected')
            $ipps = @($conns | Where-Object { $_.ConnectionUri -match 'compliance|protection' })
            $exo = @($conns | Where-Object { $_.ConnectionUri -notmatch 'compliance|protection' })
            foreach ($pair in @(@('Exchange', $exo), @('Purview', $ipps))) {
                $want = if ($pair[1].Count) { 'connected' } else { 'disconnected' }
                $s = $global:M365.State[$pair[0]]
                if ($s -ne 'error' -and $s -ne $want) { Set-M365State $pair[0] $want "$($pair[1][0].UserPrincipalName)" }
            }
        }
    }
    catch { }
}

# ------------------------------------------------------------------ Prompt & Oberfläche

$global:M365.ColorEsc = try {
    $hex = "$env:M365M_COLOR".TrimStart('#')
    "`e[38;2;{0};{1};{2}m" -f [Convert]::ToInt32($hex.Substring(0, 2), 16), [Convert]::ToInt32($hex.Substring(2, 2), 16), [Convert]::ToInt32($hex.Substring(4, 2), 16)
} catch { "`e[34m" }

function global:prompt {
    Sync-M365State
    $loc = $ExecutionContext.SessionState.Path.CurrentLocation.Path
    if ($loc.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase)) { $loc = '~' + $loc.Substring($HOME.Length) }
    $svc = @($global:M365.State.Keys | Where-Object { $global:M365.State[$_] -eq 'connected' } | ForEach-Object { $global:M365.Short[$_] }) -join ' · '
    $line = "`n$($global:M365.ColorEsc)●`e[0m `e[1m$($global:M365.Profile)`e[0m `e[90m$loc`e[0m"
    if ($svc) { $line += " `e[32m[$svc]`e[0m" }
    $line + "`n❯ "
}

if (Get-Module -ListAvailable PSReadLine) {
    $rl = @{ HistorySavePath = (Join-Path $env:M365M_DATA 'history.txt'); BellStyle = 'None' }
    try { Set-PSReadLineOption @rl -PredictionSource HistoryAndPlugin -ErrorAction Stop } catch { Set-PSReadLineOption @rl -ErrorAction SilentlyContinue }
}

$host.UI.RawUI.WindowTitle = "M365 · $($global:M365.Profile)"

Write-Host ''
Write-Host "  $($global:M365.ColorEsc)●`e[0m `e[1mM365 Manager`e[0m  `e[90m·`e[0m  $($global:M365.Profile)"
Write-Host "  `e[90mKonto `e[0m $($global:M365.Upn)"
if ($global:M365.Tenant) { Write-Host "  `e[90mTenant`e[0m $($global:M365.Tenant)" }
Write-Host ''
Write-Host "  `e[90mDienste verbinden sich automatisch mit der Browser-Anmeldung, sobald ein Befehl sie braucht (Get-MgUser, Get-Mailbox …).`e[0m"
Write-Host "  `e[90mConnect-M365 · Disconnect-M365 · Get-M365Status · `e[0mGet-M365Help"

$missing = @('Microsoft.Graph.Authentication', 'ExchangeOnlineManagement', 'MicrosoftTeams', 'PnP.PowerShell') |
    Where-Object { -not (Get-Module -ListAvailable $_) }
if ($missing) { Write-Host "  `e[33m⚠ Module fehlen noch: $($missing -join ', ') – Einrichtung im Startfenster prüfen.`e[0m" }

$custom = Join-Path $env:M365M_DATA 'custom.ps1'
if (Test-Path $custom) { . $custom }

Remove-Variable rl, missing, custom, hex -ErrorAction SilentlyContinue