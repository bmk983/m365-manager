# Tests der Token-Erneuerung im laufenden Betrieb (token-renewal.ps1 + Hooks im Bootstrap).
# Nichts wird im Tenant ausgeführt: Tokens sind unsignierte Test-JWTs, die App wird durch einen lokalen Pipe-Server ersetzt.
# Tests mit den echten Modulen (Graph/Exchange) laufen nur, wenn die Module vorhanden sind –
# Pfad über $env:M365M_TEST_MODULES (z. B. <Datenordner>\modules), sonst werden sie übersprungen.

BeforeDiscovery {
    $modules = $env:M365M_TEST_MODULES
    $script:HasGraph = [bool]($modules -and (Test-Path (Join-Path $modules 'Microsoft.Graph.Authentication')))
    $script:HasExo = [bool]($modules -and (Test-Path (Join-Path $modules 'ExchangeOnlineManagement')))
}

BeforeAll {
    $ps = Join-Path $PSScriptRoot '..\src\M365Manager\Assets\ps'
    $env:M365M_PROFILE = 'Test'; $env:M365M_UPN = 'admin@contoso.onmicrosoft.com'; $env:M365M_TENANT = 'contoso.onmicrosoft.com'
    $env:M365M_PIPE = 'm365m-test-' + [guid]::NewGuid().ToString('N')
    $env:M365M_DATA = Join-Path ([IO.Path]::GetTempPath()) ('m365m-renew-' + [guid]::NewGuid().ToString('N'))
    $env:M365M_MODULES = if ($env:M365M_TEST_MODULES) { $env:M365M_TEST_MODULES } else { Join-Path $env:M365M_DATA 'modules' }
    New-Item -ItemType Directory -Force $env:M365M_DATA | Out-Null
    . (Join-Path $ps 'bootstrap.ps1') *> $null
    $script:Hook = $ExecutionContext.InvokeCommand.PreCommandLookupAction
    $ExecutionContext.InvokeCommand.PreCommandLookupAction = $null
    $ExecutionContext.InvokeCommand.CommandNotFoundAction = $null

    $script:Tid = '00000000-0000-0000-0000-0000000000aa'
    $script:Me = '00000000-0000-0000-0000-0000000000bb'
    function New-TestJwt([string]$Marker, [string]$Aud = 'https://graph.microsoft.com', [string]$Oid = $script:Me, [int]$Minutes = 60) {
        $payload = @{ aud = $Aud; tid = $script:Tid; oid = $Oid; upn = 'admin@contoso.onmicrosoft.com'; scp = 'User.Read.All'; marker = $Marker
            exp = [DateTimeOffset]::UtcNow.AddMinutes($Minutes).ToUnixTimeSeconds(); iat = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } | ConvertTo-Json -Compress
        $b64 = { param($s) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        (& $b64 '{"alg":"none","typ":"JWT"}') + '.' + (& $b64 $payload) + '.sig'
    }
    function Get-Marker([string]$Token) { (Get-M365JwtClaims $Token).marker }

    # Lokaler Ersatz für die App: beantwortet genau eine Token-Anfrage auf der Pipe (eigener Runspace)
    function Start-FakeApp([string]$Reply, [scriptblock]$OnRequest) {
        $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $null = $ps.AddScript({
                param($Name, $Reply, $OnRequest, $Shared)
                $server = [System.IO.Pipes.NamedPipeServerStream]::new($Name, 'InOut', 4, 'Byte', 'Asynchronous')
                try {
                    $server.WaitForConnection()
                    $utf8 = [Text.UTF8Encoding]::new($false)
                    $r = [IO.StreamReader]::new($server, $utf8); $w = [IO.StreamWriter]::new($server, $utf8); $w.AutoFlush = $true
                    $line = $r.ReadLine()
                    $id = $line.Split('|')[1]
                    if ($OnRequest) { & ([scriptblock]::Create($OnRequest)) $Shared }
                    $w.WriteLine("res|$id|pending|")
                    $w.WriteLine("res|$id|$Reply")
                    Start-Sleep -Milliseconds 300
                    $line
                }
                finally { $server.Dispose() }
            }).AddArgument($env:M365M_PIPE).AddArgument($Reply).AddArgument("$OnRequest").AddArgument($global:M365Renewal)
        [pscustomobject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
    }
    function Wait-FakeApp($App) {
        $result = $App.PowerShell.EndInvoke($App.Handle)
        $App.PowerShell.Runspace.Dispose(); $App.PowerShell.Dispose()
        "$($result | Select-Object -Last 1)"
    }
}

AfterAll {
    Stop-M365TokenRenewal
    Remove-Item $env:M365M_DATA -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Hintergrund-Erneuerung (Ablauf, ohne Module)' {
    BeforeEach {
        foreach ($t in 'Expiry', 'Generation', 'RenewedAt', 'FailedAt', 'LastError') { $global:M365Renewal[$t].Clear() }
        $global:M365Renewal.GraphClaims = $null
        $global:M365Renewal.GraphExtraScopes = 'Mail.Read'
        $global:M365Renewal.LeadMinutes = 15
        Mock Set-M365GraphTokenInPlace { 1 }
    }

    It 'erneuert ein bald ablaufendes Graph-Token still (fresh,silent) und mit denselben Zusatzrechten' {
        $global:M365.Expiry['Graph'] = [DateTimeOffset]::UtcNow.AddMinutes(5)
        $exp = [DateTimeOffset]::UtcNow.AddMinutes(75).ToUnixTimeSeconds()
        $app = Start-FakeApp ('ok|' + (New-TestJwt 'neu') + '|' + $exp)
        Invoke-M365TokenRenewalPass $global:M365Renewal
        $request = Wait-FakeApp $app
        $request | Should -Match '^req\|\w+\|token\|Graph\|Mail\.Read\|fresh,silent$'
        Should -Invoke Set-M365GraphTokenInPlace -Times 1 -ParameterFilter { (Get-Marker $Token) -eq 'neu' }
        $global:M365.Expiry['Graph'].ToUnixTimeSeconds() | Should -Be $exp
        $global:M365Renewal.RenewedAt['Graph'] | Should -Not -BeNullOrEmpty
        $global:M365Renewal.GraphClaims | Should -Not -BeNullOrEmpty
        $global:M365Renewal.GraphClaims | Should -Not -Match '\.'          # nur die Claims, kein vollständiges Token
    }

    It 'lässt Tokens mit genug Restlaufzeit in Ruhe' {
        $global:M365.Expiry['Graph'] = [DateTimeOffset]::UtcNow.AddMinutes(50)
        Invoke-M365TokenRenewalPass $global:M365Renewal
        Should -Invoke Set-M365GraphTokenInPlace -Times 0
    }

    It 'überschreibt nichts, wenn das Terminal während der Anfrage neu verbunden hat' {
        $global:M365.Expiry['Graph'] = [DateTimeOffset]::UtcNow.AddMinutes(5)
        $app = Start-FakeApp ('ok|' + (New-TestJwt 'alt') + '|' + [DateTimeOffset]::UtcNow.AddMinutes(75).ToUnixTimeSeconds()) {
            param($Shared) $Shared.Generation['Graph'] = 1 + [int]$Shared.Generation['Graph'] }
        Invoke-M365TokenRenewalPass $global:M365Renewal
        $null = Wait-FakeApp $app
        Should -Invoke Set-M365GraphTokenInPlace -Times 0
    }

    It 'merkt sich einen Fehler (z. B. Anmeldung nötig) und lässt die Verbindung unverändert' {
        $before = [DateTimeOffset]::UtcNow.AddMinutes(5)
        $global:M365.Expiry['Graph'] = $before
        $app = Start-FakeApp 'err|Stille Erneuerung nicht möglich – eine Anmeldung ist nötig.'
        Invoke-M365TokenRenewalPass $global:M365Renewal
        $null = Wait-FakeApp $app
        Should -Invoke Set-M365GraphTokenInPlace -Times 0
        $global:M365.Expiry['Graph'] | Should -Be $before
        $global:M365Renewal.LastError['Graph'] | Should -Match 'Anmeldung ist nötig'
    }

    It 'übernimmt die erneuerten Claims ins Terminal (Get-M365GraphTokenInfo)' {
        $global:M365Renewal.GraphClaims = (New-TestJwt 'claims').Split('.')[1]
        (Get-M365GraphTokenInfo).Scopes | Should -Be @('User.Read.All')
        $global:M365Renewal.GraphClaims | Should -BeNullOrEmpty
    }

    It 'zeigt Ablauf und letzte Erneuerung in Get-M365Status' {
        $global:M365.Expiry['Graph'] = [DateTimeOffset]::UtcNow.AddMinutes(40)
        $global:M365Renewal.RenewedAt['Graph'] = [DateTimeOffset]::UtcNow
        $row = Get-M365Status | Where-Object Dienst -eq 'Graph'
        $row.'Token gültig bis' | Should -Match '^\d\d:\d\d:\d\d$'
        $row.Erneuert | Should -Match '^\d\d:\d\d:\d\d$'
    }
}

Describe 'Hooks: Skripte sehen dieselben Verbindungen' {
    BeforeAll { $ExecutionContext.InvokeCommand.PreCommandLookupAction = $script:Hook }
    AfterAll { $ExecutionContext.InvokeCommand.PreCommandLookupAction = $null }
    BeforeEach {
        $global:M365.Expiry.Clear()
        $global:M365.Tried.Clear()
        $global:M365.AutoConnect = $true
        $global:M365.InterceptConnect = $true
        foreach ($k in @($global:M365.State.Keys)) { $global:M365.State[$k] = 'disconnected' }
        Mock Connect-M365 { }
    }

    It 'leitet ExchangeOnlineManagement\Connect-ExchangeOnline aus Skripten auf die Browser-Anmeldung um' {
        & { ExchangeOnlineManagement\Connect-ExchangeOnline -ShowBanner:$false } *> $null
        Should -Invoke Connect-M365 -Times 1 -ParameterFilter { $Service -contains 'Exchange' }
    }

    It 'leitet Microsoft.Graph.Authentication\Connect-MgGraph -Scopes ebenfalls um' {
        & { Microsoft.Graph.Authentication\Connect-MgGraph -Scopes 'User.Read.All' -NoWelcome } *> $null
        Should -Invoke Connect-M365 -Times 1 -ParameterFilter { $Service -contains 'Graph' }
    }

    It 'reicht App-Anmeldungen (Zertifikat) unverändert an das Original durch – ohne Endlosschleife' {
        { & { ExchangeOnlineManagement\Connect-ExchangeOnline -AppId 'x' -CertificateThumbprint 'y' -Organization 'contoso.onmicrosoft.com' } } |
            Should -Throw    # Original-Cmdlet (bzw. Modul) wird erreicht
        Should -Invoke Connect-M365 -Times 0
    }

    It 'verbindet Exchange, wenn ein Skript Get-ConnectionInformation abfragt und noch nichts verbunden ist' {
        try { & { ExchangeOnlineManagement\Get-ConnectionInformation } *> $null } catch { }
        Should -Invoke Connect-M365 -Times 1 -ParameterFilter { $Service -contains 'Exchange' -and $Auto }
    }

    It 'verbindet bei Get-ConnectionInformation nicht erneut, wenn Exchange schon verbunden ist' {
        $global:M365.State['Exchange'] = 'connected'
        try { & { Get-ConnectionInformation } *> $null } catch { }
        Should -Invoke Connect-M365 -Times 0
    }

    It 'erneuert in Skripten als Notlösung kurz vor Ablauf (< 2 Minuten)' {
        $global:M365.State['Graph'] = 'connected'
        $global:M365.Expiry['Graph'] = [DateTimeOffset]::UtcNow.AddMinutes(1)
        try { & { Get-MgOrganization } *> $null } catch { }
        Should -Invoke Connect-M365 -Times 1 -ParameterFilter { $Service -contains 'Graph' -and $Force -and $Quiet }
    }

    It 'verbindet in Skripten nicht neu, solange das Token noch länger gilt' {
        $global:M365.State['Graph'] = 'connected'
        $global:M365.Expiry['Graph'] = [DateTimeOffset]::UtcNow.AddMinutes(30)
        try { & { Get-MgOrganization } *> $null } catch { }
        Should -Invoke Connect-M365 -Times 0
    }
}

Describe 'Graph: Token in der bestehenden Verbindung austauschen' -Skip:(-not $script:HasGraph) {
    BeforeAll {
        Import-Module Microsoft.Graph.Authentication
        $script:GraphCore = Get-M365LoadedAssemblies 'Microsoft.Graph.Authentication.Core' | Select-Object -First 1
        # Token, das die Anfragekette des SDK tatsächlich verwenden würde (gleicher Weg wie bei jeder Anfrage)
        function Get-SentToken {
            $flags = [Reflection.BindingFlags]'Public,NonPublic,Static,Instance'
            $session = $script:GraphCore.GetType('Microsoft.Graph.PowerShell.Authentication.GraphSession').GetProperty('Instance').GetValue($null)
            $helpers = $script:GraphCore.GetType('Microsoft.Graph.PowerShell.Authentication.Core.Utilities.AuthenticationHelpers')
            $provider = $helpers.GetMethod('GetAuthenticationProviderAsync', $flags).Invoke($null, @($session.AuthContext)).GetAwaiter().GetResult()
            $provider.GetAuthorizationTokenAsync([uri]'https://graph.microsoft.com/v1.0/organization', $null, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        }
    }
    BeforeEach {
        Microsoft.Graph.Authentication\Connect-MgGraph -AccessToken (ConvertTo-SecureString (New-TestJwt 'A') -AsPlainText -Force) -NoWelcome
    }

    It 'liefert nach dem Austausch sofort das neue Token – Verbindung und Konto bleiben' {
        Get-Marker (Get-SentToken) | Should -Be 'A'
        Set-M365GraphTokenInPlace (New-TestJwt 'B') | Should -Be 1
        Get-Marker (Get-SentToken) | Should -Be 'B'
        (Get-MgContext).TokenCredentialType | Should -Be 'UserProvidedAccessToken'
        (Get-MgContext).Account | Should -Be 'admin@contoso.onmicrosoft.com'
    }

    It 'setzt nie das Token eines anderen Kontos ein' {
        Set-M365GraphTokenInPlace (New-TestJwt 'fremd' -Oid '00000000-0000-0000-0000-0000000000ff') | Should -Be 0
        Get-Marker (Get-SentToken) | Should -Be 'A'
    }

    It 'funktioniert aus einem anderen Runspace (wie die Hintergrund-Erneuerung)' {
        $ps = [powershell]::Create()
        $null = $ps.AddScript('param($File, $Token) . $File; Set-M365GraphTokenInPlace $Token').AddArgument($global:M365Renewal.File).AddArgument((New-TestJwt 'C'))
        $ps.Invoke() | Select-Object -Last 1 | Should -Be 1
        $ps.Dispose()
        Get-Marker (Get-SentToken) | Should -Be 'C'
    }
}

Describe 'Exchange: Token in der bestehenden Verbindung austauschen' -Skip:(-not $script:HasExo) {
    BeforeAll {
        Import-Module ExchangeOnlineManagement
        $flags = [Reflection.BindingFlags]'Public,NonPublic,Static,Instance'
        $asm = Get-M365LoadedAssemblies 'Microsoft.Exchange.Management.AdminApiProvider' | Select-Object -First 1
        $script:ProviderType = $asm.GetType('Microsoft.Exchange.Management.AdminApiProvider.Authentication.ExternalAccessTokenProvider')
        $script:ContextType = $asm.GetType('Microsoft.Exchange.Management.AdminApiProvider.Authentication.TokenProviderContext')
        $script:Map = $asm.GetType('Microsoft.Exchange.Management.AdminApiProvider.Authentication.TokenProviderFactory').GetField('tokenProviderMap', $flags).GetValue($null)
        function Get-ProviderField($Object, [string]$Name) {
            $script:ProviderType.GetField($Name, [Reflection.BindingFlags]'NonPublic,Instance').GetValue($Object)
        }
        # Verbindung wie nach Connect-ExchangeOnline -AccessToken (ohne Netzwerk nachgebaut)
        function New-ExoProvider([string]$Token) {
            $f = [Reflection.BindingFlags]'NonPublic,Instance'
            $p = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($script:ProviderType)
            $c = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($script:ContextType)
            $c.AccessToken = $Token
            $script:ProviderType.GetField('context', $f).SetValue($p, $c)
            $script:ProviderType.GetField('authorizationHeader', $f).SetValue($p, 'Bearer ' + $Token)
            $infoField = $script:ProviderType.GetField('tokeninfo', $f)
            $infoField.SetValue($p, [Runtime.Serialization.FormatterServices]::GetUninitializedObject($infoField.FieldType))   # wie nach der ersten Anfrage
            $key = [guid]::NewGuid()
            $null = $script:Map.TryAdd($key, $p)
            [pscustomobject]@{ Key = $key; Provider = $p }
        }
    }
    AfterEach { foreach ($k in @($script:Map.Keys)) { $null = $script:Map.TryRemove($k, [ref]$null) } }

    It 'liest das Token bei jeder Anfrage aus authorizationHeader/tokeninfo (Vertrag mit dieser Modulversion)' {
        $m = $script:ProviderType.GetMethod('GetTokenInformation', [Reflection.BindingFlags]'Public,NonPublic,Instance')
        $il = $m.GetMethodBody().GetILAsByteArray()
        $fields = for ($i = 0; $i -lt $il.Length - 4; $i++) { if ($il[$i] -in 0x7B, 0x7D) { try { $m.Module.ResolveField([BitConverter]::ToInt32($il, $i + 1)).Name } catch { } } }
        $fields | Should -Contain 'tokeninfo'
        $fields | Should -Contain 'authorizationHeader'
    }

    It 'tauscht das Token einer Exchange-Verbindung aus und verwirft die zwischengespeicherte Token-Info' {
        $x = New-ExoProvider (New-TestJwt 'alt' -Aud 'https://outlook.office365.com')
        $new = New-TestJwt 'neu' -Aud 'https://outlook.office365.com'
        Set-M365ExoTokenInPlace $new -Service Exchange | Should -Be 1
        Get-ProviderField $x.Provider 'authorizationHeader' | Should -Be ('Bearer ' + $new)
        Get-ProviderField $x.Provider 'tokeninfo' | Should -BeNullOrEmpty
        (Get-ProviderField $x.Provider 'context').AccessToken | Should -Be $new
    }

    It 'trennt Exchange und Purview (Zielgruppe) und fasst fremde Konten nicht an' {
        $purview = New-ExoProvider (New-TestJwt 'p' -Aud 'https://ps.compliance.protection.outlook.com')
        $other = New-ExoProvider (New-TestJwt 'o' -Aud 'https://outlook.office365.com' -Oid '00000000-0000-0000-0000-0000000000ff')
        Set-M365ExoTokenInPlace (New-TestJwt 'neu' -Aud 'https://outlook.office365.com') -Service Exchange | Should -Be 0
        Get-Marker ((Get-ProviderField $purview.Provider 'context').AccessToken) | Should -Be 'p'
        Get-Marker ((Get-ProviderField $other.Provider 'context').AccessToken) | Should -Be 'o'
        Set-M365ExoTokenInPlace (New-TestJwt 'p2' -Aud 'https://ps.compliance.protection.outlook.com') -Service Purview | Should -Be 1
    }
}
