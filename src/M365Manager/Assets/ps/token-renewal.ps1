# ------------------------------------------------------------------------------
#  M365 Manager · Token-Erneuerung im laufenden Betrieb
#
#  Graph und Exchange/Purview werden mit einem Token aus der Browser-Anmeldung des Profils verbunden
#  (Connect-MgGraph -AccessToken bzw. Connect-ExchangeOnline -AccessToken). Solche Tokens erneuern die
#  Module nicht selbst – nach 60–90 Minuten käme 401. Deshalb erneuert eine Hintergrund-Erneuerung das
#  Token rechtzeitig vor Ablauf und tauscht es direkt in der bestehenden Verbindung aus:
#    - Graph:    GraphSession.Instance.InMemoryTokenCache (wird bei JEDER Anfrage gelesen)
#    - Exchange: ExternalAccessTokenProvider (authorizationHeader + tokeninfo, bei jeder Anfrage gelesen)
#  Die Verbindung selbst bleibt bestehen – auch mitten in einem laufenden Skript.
#
#  Warum nicht Connect-MgGraph -Scopes (AuthType "Delegated")? Siehe README, Abschnitt
#  "Lange Skripte und Token-Erneuerung": Das SDK würde eine eigene Anmeldung (WAM/Systembrowser,
#  eigener Token-Cache, zweite MFA) verwenden – die App meldet bewusst nur über den Profil-Browser an.
#
#  Diese Datei wird im Terminal UND im Hintergrund-Runspace geladen. Sie gibt nie Tokens aus.
# ------------------------------------------------------------------------------

# Nutzdaten (Claims) eines JWT als Objekt – ohne Prüfung der Signatur, nur zum Vergleichen.
function Get-M365JwtClaims([string]$Token) {
    try {
        $parts = "$Token".Split('.')
        if ($parts.Count -lt 2) { return $null }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    }
    catch { $null }
}

# Gehören zwei Tokens zum selben Konto und Tenant? (Nie das Token eines anderen Kontos einsetzen.)
function Test-M365SameIdentity([string]$Old, [string]$New) {
    $a = Get-M365JwtClaims $Old
    $b = Get-M365JwtClaims $New
    if (-not $a -or -not $b) { return $false }
    "$($a.tid)" -eq "$($b.tid)" -and "$($a.oid)" -eq "$($b.oid)" -and "$($a.oid)" -ne ''
}

function Get-M365LoadedAssemblies([string]$Name) {
    @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $Name })
}

<#
.SYNOPSIS
    Tauscht das Token einer per -AccessToken hergestellten Graph-Verbindung aus. Ergebnis: Anzahl ersetzter Sitzungen.
    Nur Sitzungen mit TokenCredentialType UserProvidedAccessToken desselben Kontos werden angefasst.
#>
function Set-M365GraphTokenInPlace([Parameter(Mandatory)][string]$Token) {
    $done = 0
    foreach ($asm in Get-M365LoadedAssemblies 'Microsoft.Graph.Authentication.Core') {
        $sessionType = $asm.GetType('Microsoft.Graph.PowerShell.Authentication.GraphSession')
        $cacheType = $asm.GetType('Microsoft.Graph.PowerShell.Authentication.Core.TokenCache.InMemoryTokenCache')
        if (-not $sessionType -or -not $cacheType) { continue }
        try {
            if (-not $sessionType.GetProperty('Exists').GetValue($null)) { continue }
            $session = $sessionType.GetProperty('Instance').GetValue($null)
            $ctx = $session.AuthContext
            if (-not $ctx -or "$($ctx.TokenCredentialType)" -ne 'UserProvidedAccessToken') { continue }
            $current = $session.InMemoryTokenCache
            if ($current) {
                # ReadTokenData ist intern – dieselbe Methode, mit der das SDK das Token bei jeder Anfrage liest
                $read = $cacheType.GetMethod('ReadTokenData', [Reflection.BindingFlags]'Public,NonPublic,Instance')
                $old = if ($read) { [Text.Encoding]::UTF8.GetString([byte[]]$read.Invoke($current, $null)) } else { '' }
                if (-not (Test-M365SameIdentity $old $Token)) { continue }   # Skript hat ein fremdes Token übergeben
            }
            # Ein einziger Referenz-Austausch – laufende Anfragen lesen danach das neue Token.
            $session.InMemoryTokenCache = [Activator]::CreateInstance($cacheType, [object[]]@(, [Text.Encoding]::UTF8.GetBytes($Token)))
            $done++
        }
        catch { }
    }
    $done
}

<#
.SYNOPSIS
    Tauscht das Token per -AccessToken hergestellter Exchange- bzw. Purview-Verbindungen aus (ExchangeOnlineManagement).
    Es werden nur Verbindungen mit passender Zielgruppe (aud) und demselben Konto angefasst. Ergebnis: Anzahl.
#>
function Set-M365ExoTokenInPlace([Parameter(Mandatory)][string]$Token, [ValidateSet('Exchange', 'Purview')][string]$Service = 'Exchange') {
    $audience = if ($Service -eq 'Purview') { 'ps.compliance.protection.outlook.com' } else { 'outlook.office365.com' }
    $flags = [Reflection.BindingFlags]'NonPublic,Public,Instance,Static'
    $done = 0
    foreach ($asm in Get-M365LoadedAssemblies 'Microsoft.Exchange.Management.AdminApiProvider') {
        $factory = $asm.GetType('Microsoft.Exchange.Management.AdminApiProvider.Authentication.TokenProviderFactory')
        $providerType = $asm.GetType('Microsoft.Exchange.Management.AdminApiProvider.Authentication.ExternalAccessTokenProvider')
        if (-not $factory -or -not $providerType) { continue }
        $mapField = $factory.GetField('tokenProviderMap', $flags)
        $contextField = $providerType.GetField('context', $flags)
        $headerField = $providerType.GetField('authorizationHeader', $flags)
        $infoField = $providerType.GetField('tokeninfo', $flags)
        if (-not $mapField -or -not $contextField -or -not $headerField -or -not $infoField) { continue }   # andere Modulversion
        $map = $mapField.GetValue($null)
        if (-not $map) { continue }
        foreach ($provider in @($map.Values)) {
            if (-not $providerType.IsInstanceOfType($provider)) { continue }
            try {
                $context = $contextField.GetValue($provider)
                $old = "$($context.AccessToken)"
                $aud = "$((Get-M365JwtClaims $old).aud)"
                if ($aud -notmatch [regex]::Escape($audience)) { continue }
                if (-not (Test-M365SameIdentity $old $Token)) { continue }
                # Reihenfolge wichtig: erst Header, dann die zwischengespeicherte Token-Info verwerfen –
                # die nächste Anfrage baut sie aus dem neuen Header neu auf.
                $context.AccessToken = $Token
                $headerField.SetValue($provider, 'Bearer ' + $Token)
                $infoField.SetValue($provider, $null)
                $done++
            }
            catch { }
        }
    }
    $done
}

<#
.SYNOPSIS
    Holt über eine EIGENE Verbindung zur App ein neues Token – still (nie ein Anmeldefenster).
    Für die Hintergrund-Erneuerung: blockiert den Kanal des Terminals nicht.
#>
function Invoke-M365PipeTokenRequest {
    param([Parameter(Mandatory)][string]$Pipe, [Parameter(Mandatory)][string]$Service, [string]$ExtraScopes = '', [int]$TimeoutSeconds = 90)
    $client = [System.IO.Pipes.NamedPipeClientStream]::new('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $client.Connect(5000)
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $writer = [System.IO.StreamWriter]::new($client, $utf8)
        $writer.AutoFlush = $true
        $reader = [System.IO.StreamReader]::new($client, $utf8)
        $id = [guid]::NewGuid().ToString('N')
        $writer.WriteLine("req|$id|token|$Service|$(($ExtraScopes -replace '\|', '').Trim())|fresh,silent")
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ($true) {
            $read = $reader.ReadLineAsync()
            $remaining = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not $read.Wait($remaining)) { throw 'Keine Antwort der App (Zeitüberschreitung).' }
            $line = $read.Result
            if ($null -eq $line) { throw 'Kanal zur App getrennt.' }
            $parts = $line.Split('|', 4)
            if ($parts[0] -ne 'res' -or $parts[1] -ne $id) { continue }
            switch ($parts[2]) {
                'pending' { continue }
                'ok' {
                    $t = $parts[3].Split('|', 2)
                    return [pscustomobject]@{ Token = $t[0]; ExpiresOn = [DateTimeOffset]::FromUnixTimeSeconds([long]$t[1]) }
                }
                default { throw "$($parts[3])" }
            }
        }
    }
    finally { $client.Dispose() }
}

<#
.SYNOPSIS
    Ein Durchgang der Hintergrund-Erneuerung: erneuert jeden per Token verbundenen Dienst, dessen Token
    in weniger als LeadMinutes abläuft. $Shared ist die gemeinsame (synchronisierte) Statustabelle.
#>
function Invoke-M365TokenRenewalPass($Shared) {
    foreach ($svc in 'Graph', 'Exchange', 'Purview') {
        $expiry = $Shared.Expiry[$svc]
        if (-not $expiry) { continue }                                         # nicht per Token verbunden
        if ($expiry -gt [DateTimeOffset]::UtcNow.AddMinutes($Shared.LeadMinutes)) { continue }
        $failed = $Shared.FailedAt[$svc]
        if ($failed -and $failed -gt [DateTimeOffset]::UtcNow.AddSeconds(-$Shared.RetrySeconds)) { continue }
        $generation = $Shared.Generation[$svc]
        try {
            $extra = if ($svc -eq 'Graph') { "$($Shared.GraphExtraScopes)" } else { '' }
            $t = Invoke-M365PipeTokenRequest -Pipe $Shared.Pipe -Service $svc -ExtraScopes $extra
            [System.Threading.Monitor]::Enter($Shared.Lock)
            try {
                # Inzwischen getrennt oder neu verbunden? Dann nichts überschreiben.
                if ($Shared.Generation[$svc] -ne $generation -or -not $Shared.Expiry[$svc]) { continue }
                $count = if ($svc -eq 'Graph') { Set-M365GraphTokenInPlace $t.Token } else { Set-M365ExoTokenInPlace $t.Token -Service $svc }
                if ($count -gt 0) {
                    $Shared.Expiry[$svc] = $t.ExpiresOn
                    $Shared.RenewedAt[$svc] = [DateTimeOffset]::UtcNow
                    $Shared.FailedAt.Remove($svc)
                    $Shared.LastError.Remove($svc)
                    if ($svc -eq 'Graph') { $Shared.GraphClaims = $t.Token.Split('.')[1] }   # nur die Claims, kein verwendbares Token
                }
                else {
                    $Shared.FailedAt[$svc] = [DateTimeOffset]::UtcNow
                    $Shared.LastError[$svc] = 'Keine passende Verbindung zum Austauschen gefunden.'
                }
            }
            finally { [System.Threading.Monitor]::Exit($Shared.Lock) }
        }
        catch {
            $Shared.FailedAt[$svc] = [DateTimeOffset]::UtcNow
            $Shared.LastError[$svc] = "$($_.Exception.Message)"
        }
    }
}

# Schleife des Hintergrund-Runspace (prüft alle CheckSeconds Sekunden, endet bei $Shared.Stop).
function Start-M365TokenRenewalLoop($Shared) {
    while (-not $Shared.Stop) {
        try { Invoke-M365TokenRenewalPass $Shared } catch { }
        $until = [DateTime]::UtcNow.AddSeconds($Shared.CheckSeconds)
        while (-not $Shared.Stop -and [DateTime]::UtcNow -lt $until) { [System.Threading.Thread]::Sleep(500) }
    }
}
