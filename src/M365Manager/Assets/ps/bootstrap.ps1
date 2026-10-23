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
    InterceptConnect = $true
    StrictPreflight  = $false
    GraphToken  = $null
    ExtraGraphScopes = @()
    ScopeDeclined = @{}
    SpUrl       = $null
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

. (Join-Path $PSScriptRoot 'permissions.ps1')
$global:M365OpCache = @{}
$global:M365ProxiedCommands = @()

# ------------------------------------------------------------------ Rückkanal zur App

function Open-M365Channel {
    if ($global:M365Pipe -and $global:M365Pipe.IsConnected) { return }
    # Asynchron öffnen: Nur so lässt sich die Leitung auch während eines laufenden Lesevorgangs schließen.
    # (Bei synchronen Handles blockiert Windows das Schließen, bis der Lesevorgang endet – im Fehlerfall nie.)
    $global:M365Pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $env:M365M_PIPE, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
    $global:M365Pipe.Connect(8000)
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
        [Parameter(Mandatory)][ValidateSet('Graph', 'Exchange', 'Purview', 'Teams', 'TeamsGraph', 'SharePoint', 'SharePointSite')][string]$Service,
        [string[]]$ExtraScopes,
        [switch]$Fresh,    # kein zwischengespeichertes Token verwenden – neu ausstellen lassen
        [switch]$Reauth    # zusätzlich interaktiv neu anmelden (z. B. nach Claims Challenge)
    )
    $flags = @($(if ($Fresh -or $Reauth) { 'fresh' }), $(if ($Reauth) { 'reauth' }) | Where-Object { $_ }) -join ','
    $answer = Invoke-M365HostRequest "token|$Service|$(($ExtraScopes -join ' ') -replace '\|', '')|$flags" -What "Token-Anfrage $Service"
    $parts = $answer.Split('|', 2)
    [pscustomobject]@{
        Token     = $parts[0]
        ExpiresOn = [DateTimeOffset]::FromUnixTimeSeconds([long]$parts[1])
    }
}

function Invoke-M365HostRequest {
    <#
    .SYNOPSIS
        Schickt eine Anfrage an die App und wartet auf die Antwort (Text nach "ok|").
    #>
    param([Parameter(Mandatory)][string]$Request, [string]$What = 'Anfrage')
    if (-not $env:M365M_PIPE) { throw 'Kein Kanal zur App vorhanden.' }

    # Nie blind warten: Die App meldet sich während der Bearbeitung alle 10 s ("pending").
    # Bleibt sie 45 s stumm, ist der Kanal gestört -> neu verbinden und die Anfrage einmal wiederholen.
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try { Open-M365Channel }
        catch {
            Reset-M365Channel
            if ($attempt -eq 2) { throw 'Keine Verbindung zur App möglich. Bitte das Terminal neu starten (↻).' }
            continue
        }
        $id = [guid]::NewGuid().ToString('N')
        try { $global:M365PipeWriter.WriteLine("req|$id|$Request") }
        catch { Reset-M365Channel; if ($attempt -eq 2) { throw "Kanal zur App gestört: $($_.Exception.Message)" }; continue }

        $deadline = (Get-Date).AddSeconds(45)
        $waitingNoted = $false
        while ($true) {
            # Lesen in kleinen Schritten, damit Strg+C wirkt. Eine offene Leseoperation wird wiederverwendet.
            if (-not $global:M365PendingRead) { $global:M365PendingRead = $global:M365PipeReader.ReadLineAsync() }
            while (-not $global:M365PendingRead.Wait(200)) {
                if ((Get-Date) -gt $deadline) { break }
            }
            if (-not $global:M365PendingRead.IsCompleted) { break }   # Zeitüberschreitung

            $line = if ($global:M365PendingRead.IsFaulted) { $null } else { $global:M365PendingRead.Result }
            $global:M365PendingRead = $null
            if ($null -eq $line) { break }                              # Kanal getrennt

            $parts = $line.Split('|', 4)
            if ($parts[0] -ne 'res' -or $parts[1] -ne $id) { continue }
            switch ($parts[2]) {
                'pending' {
                    if ($parts[3]) { Write-M365 $parts[3] DarkGray; $deadline = (Get-Date).AddMinutes(15); $waitingNoted = $true }   # Fenster offen: Zeit lassen
                    elseif ($deadline -lt (Get-Date).AddSeconds(45)) { $deadline = (Get-Date).AddSeconds(45) }
                    if (-not $waitingNoted -and -not $parts[3]) { Write-M365 'Warte auf die App …' DarkGray; $waitingNoted = $true }
                    continue
                }
                'ok' { return $(if ($parts.Count -gt 3) { $parts[3] } else { '' }) }
                default { throw $parts[3] }
            }
        }

        Reset-M365Channel
        if ($attempt -eq 1) { Write-M365 'Keine Antwort von der App – baue die Verbindung neu auf und versuche es erneut …' DarkYellow }
    }
    Send-M365Host "log|${What}: keine Antwort der App nach zwei Versuchen"
    throw 'Die App antwortet nicht. Bitte das Terminal neu starten (↻).'
}

function Reset-M365Channel {
    try { if ($global:M365Pipe) { $global:M365Pipe.Dispose() } } catch { }
    $global:M365Pipe = $null
    $global:M365PendingRead = $null
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
        [switch]$Quiet,
        [switch]$Fresh,
        [switch]$Reauth
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

        $wasConnected = $global:M365.State[$svc] -eq 'connected'
        $global:M365.Busy = $true
        Set-M365State $svc 'connecting'
        if (-not $Quiet) {
            if ($Auto) { Write-M365 "Befehl benötigt $svc → verbinde als $upn …" Cyan }
            else { Write-M365 "Verbinde $svc als $upn …" Cyan }
        }

        try {
            $module = $global:M365ModuleFor[$svc]
            if (-not (Get-Module -ListAvailable $module)) {
                throw "Das Modul $module fehlt. Beheben: Install-M365Module $module  (oder im Startfenster 'Nach Updates suchen')"
            }
            # Beim Erneuern die alte Exchange-/Purview-Verbindung zuerst trennen, sonst sammeln sich Sitzungen an.
            if ($wasConnected -and $svc -in 'Exchange', 'Purview') { Disconnect-M365ExoConnection -Compliance:($svc -eq 'Purview') }

            $detail = $upn
            $global:M365.Expiry.Remove($svc)
            $tokenOk = $false
            if ($useToken) {
                try {
                    $expires = Connect-M365WithToken $svc $Scopes -Fresh:$Fresh -Reauth:$Reauth
                    $global:M365.Expiry[$svc] = $expires
                    $tokenOk = $true
                    if ($svc -eq 'SharePoint') { $detail = if ($global:M365.SpUrl) { $global:M365.SpUrl } else { "https://$($global:M365.SpTenant)-admin.sharepoint.com" } }
                }
                catch {
                    Write-M365 "Übernahme der Browser-Anmeldung nicht möglich: $($_.Exception.Message)" DarkYellow
                    Write-M365 'Nutze stattdessen die normale Anmeldung des Moduls …' DarkGray
                }
            }
            if (-not $tokenOk) { $detail = Connect-M365Classic $svc $Scopes }

            Set-M365State $svc 'connected' $detail
            if ($Quiet) { Write-M365 "↻ $svc-Anmeldung erneuert." DarkGray }
            else {
                Write-M365 "✓ $svc verbunden." Green
                # IntelliSense im Editor über die Befehle dieser Verbindung informieren
                if ($svc -eq 'Exchange') { Export-M365CompletionStub Exchange Get-Recipient }
                elseif ($svc -eq 'Purview') { Export-M365CompletionStub Purview Get-DlpCompliancePolicy }
            }
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

$global:M365ModuleFor = @{
    Graph      = 'Microsoft.Graph.Authentication'
    Exchange   = 'ExchangeOnlineManagement'
    Purview    = 'ExchangeOnlineManagement'
    Teams      = 'MicrosoftTeams'
    SharePoint = 'PnP.PowerShell'
}

# Schreibt nach dem Verbinden eine "Bauplan-Datei" mit allen Befehlen + Parametern des Dienstes,
# damit IntelliSense im Skript-Editor auch Get-Recipient & Co. kennt. Enthält keine Funktion und keine Zugangsdaten.
# Läuft in einem eigenen Thread, das Terminal wird nicht ausgebremst.
function Export-M365CompletionStub([string]$Service, [string]$ProbeCommand) {
    if (-not $env:M365M_DATA) { return }
    try {
        $module = (Get-Command $ProbeCommand -ErrorAction Stop).Module
        if (-not $module) { return }
        $commands = @(Get-Command -Module $module.Name -CommandType Function, Cmdlet -ErrorAction Stop)
        $target = Join-Path $env:M365M_DATA ("completion\" + $Service.ToLowerInvariant() + ".psm1")
        $null = Start-ThreadJob -ArgumentList $commands, $target -ScriptBlock {
            param($commands, $target)
            $sb = [System.Text.StringBuilder]::new()
            $null = $sb.AppendLine('# Automatisch erzeugt von M365 Manager – nur für IntelliSense im Skript-Editor, ohne Funktion.')
            foreach ($c in $commands) {
                try {
                    $meta = [System.Management.Automation.CommandMetadata]::new($c)
                    $binding = [System.Management.Automation.ProxyCommand]::GetCmdletBindingAttribute($meta)
                    $params = [System.Management.Automation.ProxyCommand]::GetParamBlock($meta)
                    $null = $sb.AppendLine("function $($c.Name) {").AppendLine($binding).AppendLine("param($params)").AppendLine('}')
                }
                catch { }
            }
            New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
            $tmp = "$target.tmp"
            [IO.File]::WriteAllText($tmp, $sb.ToString(), [System.Text.UTF8Encoding]::new($true))
            Move-Item $tmp $target -Force
        }
    }
    catch { }
}

# Trennt nur die Exchange- bzw. Purview-Verbindung(en), die jeweils andere bleibt bestehen.
function Disconnect-M365ExoConnection([switch]$Compliance) {
    if (-not (Get-Module ExchangeOnlineManagement)) { return }
    $conns = @(Get-ConnectionInformation -ErrorAction SilentlyContinue |
        Where-Object { ($_.ConnectionUri -match 'compliance|protection') -eq [bool]$Compliance })
    foreach ($c in $conns) {
        try { Disconnect-ExchangeOnline -ConnectionId $c.ConnectionId -Confirm:$false -ErrorAction Stop | Out-Null } catch { }
    }
}

# Verbindet per Token aus der Browser-Sitzung. Gibt den Ablaufzeitpunkt zurück.
function Connect-M365WithToken([string]$Svc, [string[]]$Scopes, [switch]$Fresh, [switch]$Reauth) {
    $tenant = $global:M365.Tenant
    switch ($Svc) {
        'Graph' {
            # Einmal angeforderte Zusatz-Scopes bei jeder Erneuerung mitnehmen
            $global:M365.ExtraGraphScopes = @(@($global:M365.ExtraGraphScopes) + @($Scopes) | Where-Object { $_ } | Select-Object -Unique)
            $t = Get-M365Token Graph -ExtraScopes $global:M365.ExtraGraphScopes -Fresh:$Fresh -Reauth:$Reauth
            Connect-M365GraphNative $t.Token
            # Nur die Claims merken (Scopes, Zeiten, Rollen) – das Token selbst nicht
            Set-M365GraphTokenInfo (ConvertFrom-M365Jwt $t.Token)
            return $t.ExpiresOn
        }
        'Exchange' {
            $t = Get-M365Token Exchange
            $p = @{ AccessToken = $t.Token; Organization = $tenant; ShowBanner = $false; ErrorAction = 'Stop' }
            ExchangeOnlineManagement\Connect-ExchangeOnline @p
            return $t.ExpiresOn
        }
        'Purview' {
            $cmd = Get-Command ExchangeOnlineManagement\Connect-IPPSSession
            if (-not $cmd.Parameters.ContainsKey('AccessToken')) { throw 'Diese Version von Connect-IPPSSession kann keine Tokens übernehmen.' }
            $t = Get-M365Token Purview
            $p = @{ AccessToken = $t.Token; Organization = $tenant; ErrorAction = 'Stop' }
            if ($cmd.Parameters.ContainsKey('ShowBanner')) { $p.ShowBanner = $false }
            ExchangeOnlineManagement\Connect-IPPSSession @p
            return $t.ExpiresOn
        }
        'Teams' {
            $g = Get-M365Token TeamsGraph
            $t = Get-M365Token Teams
            MicrosoftTeams\Connect-MicrosoftTeams -AccessTokens @($g.Token, $t.Token) -ErrorAction Stop | Out-Null
            return @($g.ExpiresOn, $t.ExpiresOn) | Sort-Object | Select-Object -First 1
        }
        'SharePoint' {
            Initialize-M365SharePoint
            # Standard: Admin-Site. Hat ein Skript per Connect-PnPOnline -Url eine andere Site gewählt, diese verwenden.
            $url = if ($global:M365.SpUrl) { $global:M365.SpUrl } else { "https://$($global:M365.SpTenant)-admin.sharepoint.com" }
            $t = if ($global:M365.SpUrl) { Get-M365Token SharePointSite -ExtraScopes ([uri]$url).Host } else { Get-M365Token SharePoint }
            PnP.PowerShell\Connect-PnPOnline -Url $url -AccessToken $t.Token -ErrorAction Stop
            return $t.ExpiresOn
        }
    }
}

function Connect-M365GraphNative([string]$Token) {
    Microsoft.Graph.Authentication\Connect-MgGraph -AccessToken (ConvertTo-SecureString $Token -AsPlainText -Force) -NoWelcome -ErrorAction Stop
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
            try { Microsoft.Graph.Authentication\Connect-MgGraph @p }
            catch {
                if ($_.Exception.Message -notmatch 'WAM|broker|window handle') { throw }
                Set-MgGraphOption -DisableLoginByWAM $true
                Microsoft.Graph.Authentication\Connect-MgGraph @p
            }
            $ctx = Get-MgContext
            if (-not $ctx) { throw 'Keine Graph-Verbindung.' }
            Set-M365GraphTokenInfo $null   # Angaben kommen dann aus Get-MgContext
            return $ctx.Account
        }
        'Exchange' {
            $p = @{ ShowBanner = $false; ErrorAction = 'Stop' }
            if ($upn) { $p.UserPrincipalName = $upn }
            ExchangeOnlineManagement\Connect-ExchangeOnline @p
            return $upn
        }
        'Purview' {
            $cmd = Get-Command ExchangeOnlineManagement\Connect-IPPSSession
            $p = @{ ErrorAction = 'Stop' }
            if ($upn) { $p.UserPrincipalName = $upn }
            if ($cmd.Parameters.ContainsKey('ShowBanner')) { $p.ShowBanner = $false }
            ExchangeOnlineManagement\Connect-IPPSSession @p
            return $upn
        }
        'Teams' {
            $p = @{ ErrorAction = 'Stop' }
            if ($upn) { $p.AccountId = $upn }
            $r = MicrosoftTeams\Connect-MicrosoftTeams @p
            if ($r.Account) { return "$($r.Account)" }
            return $upn
        }
        'SharePoint' {
            Initialize-M365SharePoint
            $url = "https://$($global:M365.SpTenant)-admin.sharepoint.com"
            PnP.PowerShell\Connect-PnPOnline -Url $url -Interactive -ClientId $global:M365.PnPClientId -ErrorAction Stop
            return $url
        }
    }
}
# ------------------------------------------------------------------ Connect-* aus Skripten übernehmen
# Skripte rufen oft Connect-MgGraph, Connect-ExchangeOnline … auf. Diese Funktionen fangen solche Aufrufe ab
# und nutzen die Anmeldung aus dem Browser des Profils – ohne erneute Anmeldung/MFA. Ist der Dienst schon
# verbunden, bleibt die Verbindung bestehen. Aufrufe mit App-Anmeldung (Zertifikat, Secret, Managed Identity),
# anderem Konto oder anderem Tenant gehen unverändert an das Original-Cmdlet.
# Abschalten: Set-M365ConnectOverride $false

function ConvertFrom-M365Arguments([object[]]$Arguments) {
    $named = @{}
    $positional = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $a = $Arguments[$i]
        if ($a -is [string] -and $a -match '^-([A-Za-z]\w*)(:)?$') {
            $name = $Matches[1]
            $next = if ($i + 1 -lt $Arguments.Count) { $Arguments[$i + 1] } else { $null }
            $nextIsName = $next -is [string] -and $next -match '^-[A-Za-z]'
            if ($Matches[2] -or ($i + 1 -lt $Arguments.Count -and -not $nextIsName)) { $named[$name] = $next; $i++ }
            else { $named[$name] = $true }
        }
        else { $positional.Add($a) }
    }
    [pscustomobject]@{ Named = $named; Positional = $positional }
}

# Ruft ein Cmdlet mit den zerlegten Argumenten auf: benannte als Hashtable, übrige positionell.
# Zuverlässiger als @args, das z. B. "-ShowBanner:$false" nicht korrekt weiterreicht.
function Invoke-M365Native([string]$Native, $Parsed, [hashtable]$Extra = @{}, [object[]]$PipelineInput, [switch]$FromPipeline) {
    $named = @{} + $Parsed.Named + $Extra
    $positional = [System.Collections.Generic.List[object]]::new()
    # Schalter ohne ":" vor einem Positionswert (z. B. -ShowBanner 'contoso'): Wert gehört nicht zum Schalter
    $params = try { (Get-Command $Native -ErrorAction Stop).Parameters } catch { $null }
    if ($params) {
        foreach ($key in @($named.Keys)) {
            if ($params.ContainsKey($key) -and $params[$key].SwitchParameter -and $named[$key] -isnot [bool] -and $named[$key] -isnot [System.Management.Automation.SwitchParameter]) {
                $positional.Add($named[$key])
                $named[$key] = $true
            }
        }
    }
    foreach ($v in $Parsed.Positional) { $positional.Add($v) }
    $positional = @($positional)
    if ($FromPipeline) { $PipelineInput | & $Native @named @positional }
    else { & $Native @named @positional }
}

function Test-M365SameValue($Value, [string]$Expected) {
    -not $Value -or ($Expected -and "$Value".Trim().Equals($Expected.Trim(), [StringComparison]::OrdinalIgnoreCase))
}

function Invoke-M365Intercepted {
    param([string]$Service, [string]$Native, [object[]]$Arguments, [string[]]$Allowed, [scriptblock]$Condition, [scriptblock]$Action, [scriptblock]$OnPassThrough)
    $p = ConvertFrom-M365Arguments $Arguments
    $foreign = @($p.Named.Keys | Where-Object { $_ -notin $Allowed })
    $take = $global:M365.InterceptConnect -and $env:M365M_PIPE -and $foreign.Count -eq 0 -and $p.Positional.Count -eq 0 -and (& $Condition $p.Named)
    if (-not $take) {
        Invoke-M365Native $Native $p
        if ($OnPassThrough) { & $OnPassThrough $p.Named }
        return
    }
    $name = ($Native -split '\\')[-1]
    Write-M365 "↪ $name → Anmeldung aus dem Browser des Profils (M365 Manager)" DarkGray
    & $Action $p.Named
}

function global:Connect-MgGraph {
    Invoke-M365Intercepted -Service Graph -Native 'Microsoft.Graph.Authentication\Connect-MgGraph' -Arguments $args `
        -Allowed 'Scopes', 'NoWelcome', 'TenantId', 'ContextScope' `
        -Condition { param($n) Test-M365SameValue $n.TenantId $global:M365.Tenant } `
        -OnPassThrough {
            param($n)
            # Eigene Anmeldung des Skripts: bei übergebenem Token dessen Claims merken, Herkunft "Extern"
            $info = $null
            if ($n.AccessToken) {
                try {
                    $plain = if ($n.AccessToken -is [securestring]) { [System.Net.NetworkCredential]::new('', $n.AccessToken).Password } else { "$($n.AccessToken)" }
                    $info = ConvertFrom-M365Jwt $plain
                    $info.Source = 'Extern'
                }
                catch { }
            }
            Set-M365GraphTokenInfo $info
        } `
        -Action {
            param($n)
            $wanted = @($n.Scopes | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ })
            if ($global:M365.State.Graph -eq 'connected') {
                $info = Get-M365GraphTokenInfo   # Scopes des tatsächlich verwendeten Tokens
                $have = if ($info) { @($info.Scopes) } else { @() }
                $missing = @($wanted | Where-Object { $have -notcontains $_ })
                if (-not $missing) { Write-M365 '✓ Graph ist bereits verbunden – Verbindung wird weiterverwendet.' DarkGray; return }
                Connect-M365 Graph -Scopes $missing -Force
            }
            else { Connect-M365 Graph -Scopes $wanted }
        }
}

function global:Connect-ExchangeOnline {
    Invoke-M365Intercepted -Service Exchange -Native 'ExchangeOnlineManagement\Connect-ExchangeOnline' -Arguments $args `
        -Allowed 'UserPrincipalName', 'ShowBanner', 'ShowProgress', 'SkipLoadingFormatData', 'SkipLoadingCmdletHelp', 'DisableWAM' `
        -Condition { param($n) Test-M365SameValue $n.UserPrincipalName $global:M365.Upn } `
        -Action { if ($global:M365.State.Exchange -eq 'connected') { Write-M365 '✓ Exchange ist bereits verbunden – Verbindung wird weiterverwendet.' DarkGray } else { Connect-M365 Exchange } }
}

function global:Connect-IPPSSession {
    Invoke-M365Intercepted -Service Purview -Native 'ExchangeOnlineManagement\Connect-IPPSSession' -Arguments $args `
        -Allowed 'UserPrincipalName', 'ShowBanner', 'DisableWAM' `
        -Condition { param($n) Test-M365SameValue $n.UserPrincipalName $global:M365.Upn } `
        -Action { if ($global:M365.State.Purview -eq 'connected') { Write-M365 '✓ Purview ist bereits verbunden – Verbindung wird weiterverwendet.' DarkGray } else { Connect-M365 Purview } }
}

function global:Connect-MicrosoftTeams {
    Invoke-M365Intercepted -Service Teams -Native 'MicrosoftTeams\Connect-MicrosoftTeams' -Arguments $args `
        -Allowed 'AccountId', 'TenantId' `
        -Condition { param($n) (Test-M365SameValue $n.AccountId $global:M365.Upn) -and (Test-M365SameValue $n.TenantId $global:M365.Tenant) } `
        -Action { if ($global:M365.State.Teams -eq 'connected') { Write-M365 '✓ Teams ist bereits verbunden – Verbindung wird weiterverwendet.' DarkGray } else { Connect-M365 Teams } }
}

function global:Connect-PnPOnline {
    Invoke-M365Intercepted -Service SharePoint -Native 'PnP.PowerShell\Connect-PnPOnline' -Arguments $args `
        -Allowed 'Url', 'Interactive', 'ClientId', 'Tenant', 'LaunchBrowser' `
        -Condition {
            param($n)
            $n.Url -and "$($n.Url)" -match '^https://[a-z0-9-]+(-admin|-my)?\.sharepoint\.com(/|$)' -and
            ((-not $n.ClientId) -or (Test-M365SameValue $n.ClientId $global:M365.PnPClientId))
        } `
        -Action {
            param($n)
            $url = "$($n.Url)".TrimEnd('/')
            $admin = $url -match '^https://[^/]+-admin\.sharepoint\.com$'
            $current = if ($global:M365.SpUrl) { $global:M365.SpUrl } else { "https://$($global:M365.SpTenant)-admin.sharepoint.com" }
            if ($global:M365.State.SharePoint -eq 'connected' -and $current -eq $url) {
                Write-M365 '✓ SharePoint ist bereits mit dieser Site verbunden.' DarkGray
                return
            }
            if ($url -match '^https://([a-z0-9-]+?)(-admin|-my)?\.sharepoint\.com' -and -not $global:M365.SpTenant) { $global:M365.SpTenant = $Matches[1] }
            $global:M365.SpUrl = if ($admin) { $null } else { $url }
            Connect-M365 SharePoint -Force
        }
}

function Set-M365ConnectOverride([bool]$Enabled = $true) {
    $global:M365.InterceptConnect = $Enabled
    Write-M365 ("Connect-* aus Skripten nutzen die Browser-Anmeldung: " + $(if ($Enabled) { 'an.' } else { 'aus.' })) Cyan
}

# ------------------------------------------------------------------ Graph-Berechtigungen: anfordern, prüfen, anzeigen

function Request-M365GraphScope {
    <#
    .SYNOPSIS
        Fordert fehlende delegierte Graph-Berechtigungen inkrementell an (Zustimmung im Profil-Browser),
        holt danach ausdrücklich ein NEUES Token und prüft dessen tatsächliche Scopes.
    .EXAMPLE
        Request-M365GraphScope -Operation AuthMethods.Write
        Request-M365GraphScope -Scopes User.RevokeSessions.All
        Request-M365GraphScope -Missing      # alles, was den Funktionen der Registry fehlt
    #>
    [CmdletBinding()]
    param([string[]]$Scopes, [string]$Operation, [switch]$Missing, [switch]$Quiet)

    $info = Get-M365GraphTokenInfo
    $wanted = @($Scopes)
    if ($Operation) { $wanted += $global:M365Permissions[$Operation].Least }
    if ($Missing) {
        foreach ($key in $global:M365Permissions.Keys) {
            $def = $global:M365Permissions[$key]
            if (-not $info -or -not @($def.Accept | Where-Object { @($info.Scopes) -contains $_ })) { $wanted += $def.Least }
        }
    }
    $wanted = @($wanted | Where-Object { $_ } | Select-Object -Unique)
    if (-not $wanted) { Write-M365 '✓ Es fehlen keine Berechtigungen.' Green; return $true }

    if ($info -and -not (Test-M365ScopeEscalation $info)) {
        Write-M365 "Das aktuelle Graph-Token wurde extern übergeben ($($info.Source)). Dafür kann die App keine zusätzlichen Berechtigungen anfordern. Bitte mit 'Connect-M365 Graph -Force' über die App neu verbinden." Yellow
        return $false
    }
    if ($Missing -and -not $Quiet) {
        Write-M365 ('Fehlende Berechtigungen: ' + ($wanted -join ', ')) Cyan
        $answer = Read-Host '  Jetzt anfordern? [J/n]'
        if ($answer -and $answer -notmatch '^(j|y)') { return $false }
    }

    Write-M365 ('Fordere an: ' + ($wanted -join ', ') + ' – ggf. erscheint ein Zustimmungs-Fenster.') Cyan
    Connect-M365 Graph -Scopes $wanted -Force -Fresh -Quiet
    if ($global:M365.State.Graph -ne 'connected') {
        Write-M365 'Zustimmung bzw. Anmeldung wurde abgebrochen oder ist fehlgeschlagen – es wurde nichts geändert.' Yellow
        return $false
    }

    # Entscheidend ist, was im NEUEN Token steht – nicht, was angefordert wurde
    $global:M365ConsentCache = $null
    $now = Get-M365GraphTokenInfo
    $still = @($wanted | Where-Object { @($now.Scopes) -notcontains $_ })
    if ($still) {
        Write-M365 ('Neues Token ausgestellt, es enthält aber weiterhin nicht: ' + ($still -join ', ') + '.') Yellow
        Write-M365 'Vermutlich ist für diese Berechtigung eine Administrator-Zustimmung nötig, oder die Zustimmung wurde nicht erteilt.' DarkGray
        return $false
    }
    Write-M365 ('✓ Neues Token enthält jetzt: ' + ($wanted -join ', ')) Green
    return $true
}

function Test-M365GraphToken {
    <# .SYNOPSIS Holt ein frisches Graph-Token (still, ohne Anmeldung) und zeigt die tatsächlichen Berechtigungen. #>
    Connect-M365 Graph -Force -Fresh -Quiet
    Get-M365GraphPermissions
}

function Get-M365GraphPermissions {
    <#
    .SYNOPSIS
        Diagnose "Graph-Berechtigungen": Konto, Tenant, Client-ID, Token-Zeiten, tatsächliche Scopes,
        aktive Rollen und der Status jeder Funktion der Berechtigungs-Registry.
    #>
    $info = Get-M365GraphTokenInfo
    Write-Host ''
    Write-Host '  Graph-Berechtigungen' -ForegroundColor Cyan
    if (-not $info) { Write-M365 'Microsoft Graph ist nicht verbunden (Connect-M365 Graph).' Yellow; return }
    $ctx = Get-MgContext
    $escalation = if (Test-M365ScopeEscalation $info) { 'Erweiterung durch die App möglich' } else { 'keine automatische Erweiterung möglich' }
    $roles = Get-M365CallerRoleIds $info
    $rows = [ordered]@{
        'Account'     = $info.Account
        'Tenant-ID'   = $info.TenantId
        'Client-ID'   = "$($info.ClientId)$(if ($info.ClientId -eq $global:M365GraphClientId) { ' (Microsoft Graph Command Line Tools)' })"
        'Auth-Typ'    = "$($ctx.AuthType) · Token-Quelle: $($info.Source) · $escalation"
        'Ausgestellt' = if ($info.IssuedAt) { $info.IssuedAt.ToLocalTime().ToString('dd.MM.yyyy HH:mm:ss') } else { 'unbekannt' }
        'Läuft ab'    = if ($info.ExpiresAt) { $info.ExpiresAt.ToLocalTime().ToString('dd.MM.yyyy HH:mm:ss') } else { 'unbekannt' }
        'Rollen'      = if ($null -eq $roles) { 'unbekannt' } elseif (-not $roles) { 'keine Admin-Rolle im Token' } else { ($roles | ForEach-Object { Get-M365RoleName $_ }) -join ', ' }
        'Scopes'      = "$(@($info.Scopes).Count) im Token"
    }
    foreach ($k in $rows.Keys) { Write-Host ("  {0,-12} {1}" -f $k, $rows[$k]) }
    $live = Get-M365LiveRoleIds
    if ($null -ne $live -and $null -ne $roles) {
        $newer = @($live | Where-Object { $roles -notcontains $_ -and $global:M365DefaultUserRoleIds -notcontains $_ })
        if ($newer) {
            Write-Host ("  {0,-12} {1}" -f 'Achtung', ('Aktiv, aber noch nicht im Token: ' + (($newer | ForEach-Object { Get-M365RoleName $_ }) -join ', ') + ' → Test-M365GraphToken')) -ForegroundColor Yellow
        }
    }
    Write-Host ("  {0,-12} {1}" -f '', ((@($info.Scopes) | Sort-Object) -join ' ')) -ForegroundColor DarkGray
    Write-Host ''

    $consented = $null
    $result = foreach ($key in $global:M365Permissions.Keys) {
        $def = $global:M365Permissions[$key]
        if ($null -eq $consented -and -not @($def.Accept | Where-Object { @($info.Scopes) -contains $_ })) { $consented = Get-M365ConsentedGraphScopes }
        $s = Get-M365OperationStatus -Operation $key -Token $info -ConsentedScopes $consented -CallerRoleIds $roles -EscalationSupported (Test-M365ScopeEscalation $info)
        [pscustomobject]@{
            Funktion            = $def.Title
            Status              = $s.Status
            'Autorisiert durch' = (@($s.AuthorizedByScope, $s.AuthorizedByRole) | Where-Object { $_ }) -join ' + '
            Benötigt            = $def.Least -join ', '
            Fehlt               = $s.MissingScopes -join ', '
        }
    }
    $result | Format-Table -AutoSize -Wrap | Out-Host
    if ($result | Where-Object Fehlt) { Write-M365 'Fehlende Berechtigungen anfordern: Request-M365GraphScope -Missing' DarkGray }
}

# Prüft vor Graph-Befehlen der Registry, ob der Scope im Token steht, und fordert ihn sonst einmalig an.
function Invoke-M365ScopePreflight([string]$CommandName) {
    if ($global:M365ProxiedCommands -contains $CommandName) { return }
    if (-not $global:M365OpCache.ContainsKey($CommandName)) { $global:M365OpCache[$CommandName] = "$(Get-M365OperationForCommand $CommandName)" }
    $op = $global:M365OpCache[$CommandName]
    if (-not $op -or $global:M365.State.Graph -ne 'connected') { return }
    $info = Get-M365GraphTokenInfo
    if (-not $info) { return }
    $def = $global:M365Permissions[$op]
    if (@($def.Accept | Where-Object { @($info.Scopes) -contains $_ })) { return }
    $declined = $global:M365.ScopeDeclined[$op]
    if ($declined -and $declined -gt (Get-Date).AddMinutes(-10)) { return }
    Write-M365 "$CommandName benötigt $($def.Least -join ', ') – diese Berechtigung fehlt im aktuellen Token." Yellow
    if (-not (Request-M365GraphScope -Operation $op -Quiet)) { $global:M365.ScopeDeclined[$op] = Get-Date }
}

# Ausführung privilegierter Graph-Cmdlets (MFA-Methoden verwalten, Sessions widerrufen) mit Preflight und Fehlerdiagnose.
function Invoke-M365PrivilegedCommand([string]$Native, [string]$Operation, [object[]]$Arguments, [object[]]$PipelineInput, [switch]$FromPipeline) {
    $p = ConvertFrom-M365Arguments $Arguments
    $target = if ($p.Named.UserId) { "$($p.Named.UserId)" } elseif ($p.Positional.Count) { "$($p.Positional[0])" } else { $null }

    if ($global:M365.State.Graph -ne 'connected' -and $global:M365.AutoConnect) { Connect-M365 Graph -Auto }
    $check = Test-M365Operation -Operation $Operation -TargetUser $target
    if ($check.Status -in 'ConsentRequired', 'MissingGraphScope', 'FreshTokenRequired') {
        Write-M365 $check.Message Yellow
        if ($check.AuthorizedByScope) {
            # Scope ist da, nur das Token ist veraltet (z. B. Rolle per PIM aktiviert): neues Token holen
            Connect-M365 Graph -Force -Fresh -Quiet
            $check = Test-M365Operation -Operation $Operation -TargetUser $target
        }
        elseif (Request-M365GraphScope -Operation $Operation -Quiet) { $check = Test-M365Operation -Operation $Operation -TargetUser $target }
    }

    switch ($check.Status) {
        'Allowed' { }
        { $_ -in 'UnsupportedAuthenticationFlow', 'ConsentRequired', 'MissingGraphScope', 'FreshTokenRequired' } {
            Write-Error -Message $check.Message -ErrorId "M365.$($check.Status)" -Category PermissionDenied -TargetObject $target
            return
        }
        default {
            # MissingDirectoryRole / TargetIsPrivileged: verständlich warnen – Graph entscheidet endgültig
            Write-M365 "⚠ $($check.Message)" Yellow
            if ($global:M365.StrictPreflight) {
                Write-Error -Message $check.Message -ErrorId "M365.$($check.Status)" -Category PermissionDenied -TargetObject $target
                return
            }
            Write-M365 'Die Aktion wird trotzdem an Microsoft Graph gesendet – Graph trifft die endgültige Entscheidung. (Strenger Modus: $M365.StrictPreflight = $true)' DarkGray
        }
    }

    $stop = $p.Named.ContainsKey('ErrorAction') -and "$($p.Named.ErrorAction)" -eq 'Stop'
    try {
        # Pipeline-Eingaben (z. B. … | Revoke-MgUserSignInSession) unverändert weiterreichen
        $extra = if ($p.Named.ContainsKey('ErrorAction')) { @{} } else { @{ ErrorAction = 'Stop' } }
        Invoke-M365Native $Native $p -Extra $extra -PipelineInput $PipelineInput -FromPipeline:$FromPipeline
    }
    catch {
        Write-M365GraphDiagnostics (Resolve-M365GraphError -ErrorRecord $_ -Operation $Operation -TargetUser $target)
        if ($stop) { throw }
        Write-Error -ErrorRecord $_
    }
}

# Erzeugt für die privilegierten Cmdlets (aus der Registry) gleichnamige Funktionen, die den Preflight ausführen.
function Register-M365PrivilegedProxies {
    $sources = @(
        @{ Module = 'Microsoft.Graph.Identity.SignIns'; Operation = 'AuthMethods.Write' },
        @{ Module = 'Microsoft.Graph.Users.Actions'; Operation = 'Sessions.Revoke' }
    )
    foreach ($s in $sources) {
        $dir = Join-Path "$env:M365M_MODULES" $s.Module
        $psd1 = Get-ChildItem $dir -Recurse -Filter "$($s.Module).psd1" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if (-not $psd1) { continue }
        try { $data = Import-PowerShellDataFile $psd1.FullName } catch { continue }
        $pattern = $global:M365Permissions[$s.Operation].Pattern
        foreach ($name in @($data.FunctionsToExport) + @($data.CmdletsToExport) | Where-Object { $_ -and $_ -match $pattern } | Select-Object -Unique) {
            $body = [scriptblock]::Create("Invoke-M365PrivilegedCommand -Native '$($s.Module)\$name' -Operation '$($s.Operation)' -Arguments `$args -PipelineInput @(`$input) -FromPipeline:`$MyInvocation.ExpectingInput")
            Set-Item -Path "function:global:$name" -Value $body
            $global:M365ProxiedCommands += $name
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
                    'Graph'      { if (Get-Module Microsoft.Graph.Authentication) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }; Set-M365GraphTokenInfo $null; $global:M365ConsentCache = $null }
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
    <#
    .SYNOPSIS
        Lädt ein zusätzliches Modul portabel in den Datenordner.
        Graph-Module werden automatisch in derselben Version wie die vorhandenen installiert.
    .EXAMPLE
        Install-M365Module Microsoft.Graph.Planner
    #>
    param([Parameter(Mandatory)][string[]]$Name)
    foreach ($n in $Name) {
        $p = @{ Name = $n; Path = $env:M365M_MODULES; Repository = 'PSGallery'; TrustRepository = $true }
        if ($n -like 'Microsoft.Graph.*') {
            $gv = Get-ChildItem (Join-Path $env:M365M_MODULES 'Microsoft.Graph.Authentication') -Directory -ErrorAction SilentlyContinue |
                Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1 -ExpandProperty Name
            if ($gv) { $p.Version = "[$gv]"; $p.SkipDependencyCheck = $true }
        }
        Save-PSResource @p
        Write-M365 "✓ Installiert: $n$(if ($p.Version) { " $($p.Version)" })" Green
    }
    Write-M365 'Tipp: In einem neuen Terminal (+) ist das Modul sofort sauber verfügbar.' DarkGray
}
# ------------------------------------------------------------------ Tabellenfenster (Out-GridView)

function Format-M365GridValue($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss') }
    if ($Value -is [datetimeoffset]) { return $Value.LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss') }
    if ($Value -is [bool] -or $Value -is [enum] -or $Value -is [guid] -or $Value -is [timespan]) { return $Value.ToString() }
    if ($Value -is [ValueType]) { return $Value }                       # Zahlen bleiben Zahlen (Sortierung)
    if ($Value -is [System.Collections.IDictionary]) {
        return (@($Value.GetEnumerator() | Select-Object -First 10 | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return (@($Value | Select-Object -First 20 | ForEach-Object { Format-M365GridValue $_ }) -join ', ')
    }
    $text = "$Value"
    if ($text -ne $Value.GetType().FullName) { return $text }
    # Objekt ohne sinnvolle Textform (z. B. Graph-Typen): die ersten gefüllten Eigenschaften zeigen
    return (@($Value.PSObject.Properties | Where-Object { $_.Name -ne 'AdditionalProperties' -and $null -ne $_.Value -and "$($_.Value)" -ne '' } |
        Select-Object -First 4 | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; ')
}

function ConvertTo-M365GridData([System.Collections.Generic.List[object]]$Items, [string]$Title) {
    $sample = @($Items | Select-Object -First 50 | ForEach-Object { if ($_ -is [psobject]) { $_.PSObject.BaseObject } else { $_ } })
    $scalar = -not ($sample | Where-Object { $_ -isnot [string] -and $_ -isnot [ValueType] })

    if ($scalar) { $columns = @('Wert') }
    else {
        # Spalten: Standardansicht des Typs zuerst, dann alle weiteren Eigenschaften (Vereinigung der ersten 50 Objekte)
        $names = [System.Collections.Generic.List[string]]::new()
        $first = $Items[0]
        $display = try { $first.PSStandardMembers.DefaultDisplayPropertySet.ReferencedPropertyNames } catch { $null }
        $preferred = @($display) + @('Name', 'DisplayName', 'UserPrincipalName', 'PrimarySmtpAddress', 'Mail', 'Identity', 'Id') | Where-Object { $_ }
        $kinds = 'Property', 'NoteProperty', 'AliasProperty', 'ScriptProperty', 'CodeProperty'
        $all = foreach ($o in ($Items | Select-Object -First 50)) { ([psobject]$o).PSObject.Properties | Where-Object { $_.MemberType -in $kinds } | ForEach-Object Name }
        $all = @($all | Select-Object -Unique)
        foreach ($n in $preferred) { if ($n -in $all -and -not $names.Contains($n)) { $names.Add($n) } }
        foreach ($n in $all) { if (-not $names.Contains($n) -and $n -ne 'AdditionalProperties') { $names.Add($n) } }
        $columns = @($names)
    }

    $rows = [System.Collections.Generic.List[object]]::new($Items.Count)
    foreach ($o in $Items) {
        if ($scalar) { $rows.Add(@(, (Format-M365GridValue $o))); continue }
        $row = [object[]]::new($columns.Count)
        $props = ([psobject]$o).PSObject.Properties
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $p = $props[$columns[$i]]
            $row[$i] = if ($p) { try { Format-M365GridValue $p.Value } catch { '' } } else { '' }
        }
        $rows.Add($row)
    }

    # Spalten ohne einen einzigen Wert weglassen (Graph-Objekte haben Dutzende leere Eigenschaften)
    $keep = @(for ($i = 0; $i -lt $columns.Count; $i++) { foreach ($r in $rows) { if ("$($r[$i])" -ne '') { $i; break } } })
    if ($keep.Count -eq 0) { $keep = @(0) }
    $data = [ordered]@{
        title   = $Title
        columns = @($keep | ForEach-Object { $columns[$_] })
        rows    = @(foreach ($r in $rows) { , @($keep | ForEach-Object { $r[$_] }) })
    }
    ConvertTo-Json $data -Depth 4 -Compress
}

function Out-GridView {
    <#
    .SYNOPSIS
        Zeigt Objekte im Tabellenfenster der App (filtern, sortieren, kopieren, als CSV/Excel speichern).
        -PassThru / -OutputMode Single|Multiple: ausgewählte Zeilen kommen zurück in die Pipeline.
    #>
    [CmdletBinding(DefaultParameterSetName = 'PassThru')]
    param(
        [Parameter(ValueFromPipeline)][psobject]$InputObject,
        [string]$Title,
        [Parameter(ParameterSetName = 'PassThru')][switch]$PassThru,
        [Parameter(ParameterSetName = 'OutputMode')][ValidateSet('None', 'Single', 'Multiple')][string]$OutputMode = 'None',
        [Parameter(ParameterSetName = 'Wait')][switch]$Wait
    )
    begin { $items = [System.Collections.Generic.List[object]]::new() }
    process {
        if ($null -eq $InputObject) { return }
        if ($MyInvocation.ExpectingInput) { $items.Add($InputObject) }
        else { foreach ($x in $InputObject) { if ($null -ne $x) { $items.Add($x) } } }
    }
    end {
        $mode = if ($PassThru) { 'multiple' } elseif ($OutputMode -ne 'None') { $OutputMode.ToLowerInvariant() } elseif ($Wait) { 'wait' } else { 'none' }
        if (-not $Title) { $Title = ($MyInvocation.Line.Trim() -replace '\s+', ' ') }
        if ($Title.Length -gt 140) { $Title = $Title.Substring(0, 137) + '…' }

        if (-not $env:M365M_PIPE) {
            $items | Format-Table -AutoSize | Out-Host
            if ($mode -in 'multiple', 'single') { return $items }
            return
        }
        if ($items.Count -eq 0) { Write-M365 'Out-GridView: keine Daten.' DarkGray; return }
        if ($items.Count -gt 2000) { Write-M365 "Bereite $($items.Count) Zeilen für das Tabellenfenster auf …" DarkGray }

        $payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((ConvertTo-M365GridData $items $Title)))
        if ($mode -eq 'none') { Send-M365Host "grid|none|$payload"; return }

        $answer = Invoke-M365HostRequest "grid|$mode|$payload" -What 'Tabellenfenster'
        if ($mode -eq 'wait' -or -not $answer) { return }
        foreach ($i in $answer.Split(',')) { if ($i -match '^\d+$' -and [int]$i -lt $items.Count) { $items[[int]$i] } }
    }
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
    Write-Host "  Set-M365ConnectOverride `$false                              Connect-* aus Skripten nicht abfangen"
    Write-Host "  … | Out-GridView [-PassThru]                                 Tabellenfenster: filtern, sortieren, Excel/CSV"
    Write-Host ''
    Write-Host "  ${c}Graph-Berechtigungen${r}"
    Write-Host "  Get-M365GraphPermissions                                     Token, Scopes, Rollen, Status je Funktion"
    Write-Host "  Request-M365GraphScope -Missing                              fehlende Berechtigungen anfordern"
    Write-Host "  Test-M365GraphToken                                          frisches Token holen und erneut prüfen"
    Write-Host "  Connect-M365 Graph -Reauth                                   neu authentifizieren (z. B. nach Conditional Access)"
    Write-Host "  Test-M365Operation AuthMethods.Write -TargetUser <UPN>      Preflight für ein Zielkonto"
    Write-Host "  Get-M365LastGraphError                                       letzten Graph-Fehler analysieren"
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
    param([string]$CommandName, [System.Management.Automation.CommandLookupEventArgs]$LookupArgs)
    if ($global:M365.Busy -or -not $global:M365.AutoConnect) { return }
    if ($CommandName -notmatch '^[A-Za-z]+-[A-Za-z0-9]+$') { return }   # interne Modul-Befehle (mit "_") ignorieren
    if ($LookupArgs.CommandOrigin -eq 'Runspace') {
        Update-M365Connection $CommandName | Out-Null
        $svc = Resolve-M365Service $CommandName
        if ($svc -and $global:M365.State[$svc] -ne 'connected' -and -not $global:M365.Tried[$svc]) { Connect-M365 -Service $svc -Auto }
    }
    # Fehlende Graph-Berechtigung für Funktionen der Registry rechtzeitig anfordern – auch in Skripten
    if ($CommandName -match '-Mg') {
        $global:M365.Busy = $true
        try { Invoke-M365ScopePreflight $CommandName } finally { $global:M365.Busy = $false }
    }
}
$ExecutionContext.InvokeCommand.CommandNotFoundAction = {
    param([string]$CommandName, [System.Management.Automation.CommandLookupEventArgs]$LookupArgs)
    if ($global:M365.Busy -or -not $global:M365.AutoConnect) { return }
    $svc = Resolve-M365Service $CommandName -NotFound
    if (-not $svc -or $global:M365.State[$svc] -eq 'connected' -or $global:M365.Tried[$svc]) { return }
    Connect-M365 -Service $svc -Auto
    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($cmd) {
        $LookupArgs.Command = $cmd
        $LookupArgs.StopSearch = $true
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

# Preflight für MFA-Methoden verwalten und Sessions widerrufen aktivieren
try { Register-M365PrivilegedProxies } catch { }

# Kanal zur App sofort belegen – die App akzeptiert nur diesen PowerShell-Prozess.
if ($env:M365M_PIPE) { try { Open-M365Channel } catch { } }

$custom = Join-Path $env:M365M_DATA 'custom.ps1'
if (Test-Path $custom) { . $custom }

Remove-Variable rl, missing, custom, hex -ErrorAction SilentlyContinue