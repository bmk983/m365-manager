# Tests der Graph-Berechtigungslogik (Registry, Token-Prüfung, Preflight, Consent-Ablauf, Fehlerdiagnose).
# Es wird nichts im Tenant ausgeführt – Graph, Token-Broker und Verbindungen werden simuliert.

BeforeAll {
    $ps = Join-Path $PSScriptRoot '..\src\M365Manager\Assets\ps'
    $env:M365M_PROFILE = 'Test'; $env:M365M_UPN = 'admin@contoso.onmicrosoft.com'; $env:M365M_TENANT = 'contoso.onmicrosoft.com'
    $env:M365M_PIPE = 'm365m-test-pipe'
    $env:M365M_DATA = Join-Path ([IO.Path]::GetTempPath()) ('m365m-tests-' + [guid]::NewGuid().ToString('N'))
    $env:M365M_MODULES = Join-Path $env:M365M_DATA 'modules'
    New-Item -ItemType Directory -Force $env:M365M_MODULES | Out-Null
    . (Join-Path $ps 'bootstrap.ps1') *> $null
    # Bootstrap-Hooks für die Tests abschalten
    $ExecutionContext.InvokeCommand.PreCommandLookupAction = $null
    $ExecutionContext.InvokeCommand.CommandNotFoundAction = $null

    function New-TestToken([string[]]$Scopes, [string[]]$Roles = @(), [int]$ExpiresInMinutes = 60, [int]$IssuedMinutesAgo = 1) {
        $now = [DateTimeOffset]::UtcNow
        $payload = @{
            scp = ($Scopes -join ' '); tid = '00000000-0000-0000-0000-0000000000aa'; appid = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
            upn = 'admin@contoso.onmicrosoft.com'; oid = '00000000-0000-0000-0000-0000000000bb'; wids = @($Roles + 'b79fbf4d-3ef9-4689-8143-76b194e85509')
            iat = $now.AddMinutes(-$IssuedMinutesAgo).ToUnixTimeSeconds(); exp = $now.AddMinutes($ExpiresInMinutes).ToUnixTimeSeconds()
        } | ConvertTo-Json -Compress
        $b64 = { param($s) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        (& $b64 '{"alg":"none"}') + '.' + (& $b64 $payload) + '.sig'
    }
    $script:AuthAdmin = 'c4e39bd9-1100-46d3-8c65-fb160da0071f'
    $script:PrivAuthAdmin = '7be44c8a-adaf-4e2a-84d6-ab2649e08a13'
    $script:UserAdmin = 'fe930be7-5e62-47db-91af-98c3a49a38b1'
    $script:GlobalAdmin = '62e90394-69f5-4237-9190-012177145e10'
    $script:BaseScopes = @('User.Read.All', 'Directory.Read.All', 'UserAuthenticationMethod.Read.All')

    Add-Type -TypeDefinition @"
public class FakeGraphException : System.Exception {
    public FakeGraphException(string message, System.Net.Http.HttpResponseMessage response) : base(message) { Response = response; }
    public System.Net.Http.HttpResponseMessage Response { get; private set; }
}
"@ -ReferencedAssemblies System.Net.Http, System.Net.Primitives
    function New-GraphError([int]$Status, [string]$Body, [hashtable]$Headers = @{}) {
        $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$Status)
        $resp.RequestMessage = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, 'https://graph.microsoft.com/v1.0/users/x/revokeSignInSessions')
        foreach ($k in $Headers.Keys) { $null = $resp.Headers.TryAddWithoutValidation($k, $Headers[$k]) }
        [System.Management.Automation.ErrorRecord]::new([FakeGraphException]::new($Body, $resp), 'Test', 'NotSpecified', $null)
    }
}

AfterAll { Remove-Item $env:M365M_DATA -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'Token-Claims' {
    It 'liest Scopes, Tenant, Client-ID, Rollen und Zeiten aus dem Token' {
        $info = ConvertFrom-M365Jwt (New-TestToken -Scopes 'User.Read.All', 'AuditLog.Read.All' -Roles $AuthAdmin)
        $info.Scopes | Should -Be @('User.Read.All', 'AuditLog.Read.All')
        $info.ClientId | Should -Be '14d82eec-204b-4c2f-b7e8-296a70dab67e'
        $info.RoleIds | Should -Be @($AuthAdmin)      # Standard-Benutzerrolle wird herausgefiltert
        $info.ExpiresAt | Should -BeGreaterThan ([DateTimeOffset]::UtcNow)
        $info.Source | Should -Be 'Broker'
    }
    It 'ordnet Cmdlets den Funktionen der Registry zu' {
        Get-M365OperationForCommand 'Get-MgUserAuthenticationMethod' | Should -Be 'AuthMethods.Read'
        Get-M365OperationForCommand 'New-MgUserAuthenticationPhoneMethod' | Should -Be 'AuthMethods.Write'
        Get-M365OperationForCommand 'Remove-MgBetaUserAuthenticationFido2Method' | Should -Be 'AuthMethods.Write'
        Get-M365OperationForCommand 'Revoke-MgUserSignInSession' | Should -Be 'Sessions.Revoke'
        Get-M365OperationForCommand 'Get-MgAuditLogDirectoryAudit' | Should -Be 'AuditLogs.Read'
        Get-M365OperationForCommand 'Get-MgUser' | Should -BeNullOrEmpty
    }
}

Describe 'Scope-Prüfung gegen den tatsächlichen Token' {
    It 'Read-Scope vorhanden, Write-Scope fehlt' {
        $t = ConvertFrom-M365Jwt (New-TestToken -Scopes $BaseScopes -Roles $AuthAdmin)
        (Get-M365OperationStatus -Operation 'AuthMethods.Read' -Token $t -CallerRoleIds $t.RoleIds).Status | Should -Be 'Allowed'
        $w = Get-M365OperationStatus -Operation 'AuthMethods.Write' -Token $t -ConsentedScopes $BaseScopes -CallerRoleIds $t.RoleIds
        $w.Status | Should -Be 'ConsentRequired'
        $w.MissingScopes | Should -Be @('UserAuthenticationMethod.ReadWrite.All')
        $w.Message | Should -Match 'UserAuthenticationMethod.ReadWrite.All fehlt'
        $w.Message | Should -Match 'Authentication Administrator'     # Rolle vorhanden, Scope fehlt – beides wird genannt
    }
    It 'Write-Scope nach Consent vorhanden' {
        $t = ConvertFrom-M365Jwt (New-TestToken -Scopes ($BaseScopes + 'UserAuthenticationMethod.ReadWrite.All') -Roles $AuthAdmin)
        $s = Get-M365OperationStatus -Operation 'AuthMethods.Write' -Token $t -CallerRoleIds $t.RoleIds -TargetRoleIds @()
        $s.Status | Should -Be 'Allowed'
        $s.AuthorizedByScope | Should -Be 'UserAuthenticationMethod.ReadWrite.All'
        $s.AuthorizedByRole | Should -Be 'Authentication Administrator'
    }
    It 'alter Token trotz erteiltem Consent' {
        $t = ConvertFrom-M365Jwt (New-TestToken -Scopes $BaseScopes -Roles $AuthAdmin)
        $s = Get-M365OperationStatus -Operation 'AuthMethods.Write' -Token $t -ConsentedScopes ($BaseScopes + 'UserAuthenticationMethod.ReadWrite.All') -CallerRoleIds $t.RoleIds
        $s.Status | Should -Be 'FreshTokenRequired'
        $s.Message | Should -Match 'vor der Berechtigungserweiterung ausgestellt'
    }
    It 'Scope nur konfiguriert, aber nicht im Token, gilt nicht als erlaubt' {
        $global:M365.GraphScopes = @('UserAuthenticationMethod.ReadWrite.All')   # konfiguriert …
        $t = ConvertFrom-M365Jwt (New-TestToken -Scopes $BaseScopes -Roles $AuthAdmin) # … aber nicht im Token
        (Get-M365OperationStatus -Operation 'AuthMethods.Write' -Token $t -CallerRoleIds $t.RoleIds).Status | Should -Not -Be 'Allowed'
    }
    It 'abgelaufener Token' {
        $t = ConvertFrom-M365Jwt (New-TestToken -Scopes ($BaseScopes + 'UserAuthenticationMethod.ReadWrite.All') -ExpiresInMinutes -5)
        (Get-M365OperationStatus -Operation 'AuthMethods.Write' -Token $t).Status | Should -Be 'FreshTokenRequired'
    }
    It 'Rolle fehlt trotz Scope' {
        $t = ConvertFrom-M365Jwt (New-TestToken -Scopes ($BaseScopes + 'UserAuthenticationMethod.ReadWrite.All') -Roles '29232cdf-9323-42fd-ade2-1d097af3e4de')
        (Get-M365OperationStatus -Operation 'AuthMethods.Write' -Token $t -CallerRoleIds $t.RoleIds).Status | Should -Be 'MissingDirectoryRole'
    }
}

Describe 'Sessions widerrufen' {
    It 'Session-Revoke über User.RevokeSessions.All' {
        $t = ConvertFrom-M365Jwt (New-TestToken -Scopes 'User.Read.All', 'User.RevokeSessions.All' -Roles $UserAdmin)
        $s = Get-M365OperationStatus -Operation 'Sessions.Revoke' -Token $t -CallerRoleIds $t.RoleIds -TargetRoleIds @()
        $s.Status | Should -Be 'Allowed'
        $s.AuthorizedByScope | Should -Be 'User.RevokeSessions.All'
        $s.Endpoint | Should -Be 'POST /v1.0/users/{id}/revokeSignInSessions'
    }
    It 'Session-Revoke über kompatiblen höheren Scope' {
        $t = ConvertFrom-M365Jwt (New-TestToken -Scopes 'User.ReadWrite.All' -Roles $UserAdmin)
        $s = Get-M365OperationStatus -Operation 'Sessions.Revoke' -Token $t -CallerRoleIds $t.RoleIds -TargetRoleIds @()
        $s.Status | Should -Be 'Allowed'
        $s.AuthorizedByScope | Should -Be 'User.ReadWrite.All'
    }
}

Describe 'Zielkonto' {
    It 'Ziel ist normaler Benutzer' {
        $t = ConvertFrom-M365Jwt (New-TestToken -Scopes 'UserAuthenticationMethod.ReadWrite.All' -Roles $AuthAdmin)
        (Get-M365OperationStatus -Operation 'AuthMethods.Write' -Token $t -CallerRoleIds $t.RoleIds -TargetRoleIds @('a0b1b346-4d3e-4e8b-98f8-753987be4970') -TargetUser 'user@contoso.com').Status | Should -Be 'Allowed'
    }
    It 'Ziel ist privilegierter Benutzer – Authentication Administrator reicht nicht' {
        $t = ConvertFrom-M365Jwt (New-TestToken -Scopes 'UserAuthenticationMethod.ReadWrite.All' -Roles $AuthAdmin)
        $s = Get-M365OperationStatus -Operation 'AuthMethods.Write' -Token $t -CallerRoleIds $t.RoleIds -TargetRoleIds @($GlobalAdmin) -TargetUser 'ga@contoso.com'
        $s.Status | Should -Be 'TargetIsPrivileged'
        $s.Message | Should -Match 'Privileged Authentication Administrator'
        $s.TargetRoles | Should -Be @('Global Administrator')
    }
    It 'Ziel mit unbekannter Admin-Rolle (Business Central Administrator) ist geschützt – mit Klarnamen' {
        $bcAdmin = '963797fb-eb3b-4cde-8ce3-5878b3f32a3f'
        Mock Invoke-M365GraphGet { [pscustomobject]@{ value = @([pscustomobject]@{ id = $bcAdmin; templateId = $bcAdmin; displayName = 'Dynamics 365 Business Central Administrator' }) } }
        $global:M365RoleNameCache = $null
        $t = ConvertFrom-M365Jwt (New-TestToken -Scopes 'UserAuthenticationMethod.ReadWrite.All' -Roles $AuthAdmin, $UserAdmin)
        $s = Get-M365OperationStatus -Operation 'AuthMethods.Write' -Token $t -CallerRoleIds $t.RoleIds -TargetRoleIds @($bcAdmin) -TargetUser 'svc@contoso.com'
        $s.Status | Should -Be 'TargetIsPrivileged'
        $s.Message | Should -Match 'Dynamics 365 Business Central Administrator'
        $s.Message | Should -Match 'Privileged Authentication Administrator'
    }
    It 'Zielkonto: PIM-berechtigte Rollen, rollenzuweisbare Gruppen und eingeschränkte Verwaltungseinheiten zählen mit' {
        Mock Invoke-M365GraphGet {
            switch -Wildcard ($Uri) {
                '*select=id' { [pscustomobject]@{ id = 'u1' } }
                '*microsoft.graph.directoryRole*' { [pscustomobject]@{ value = @() } }
                '*roleEligibilityScheduleInstances*' { [pscustomobject]@{ value = @([pscustomobject]@{ roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10' }) } }
                '*roleAssignments*' { [pscustomobject]@{ value = @([pscustomobject]@{ roleDefinitionId = 'c0ffee00-0000-0000-0000-00000000c0de' }) } }   # benutzerdefinierte Rolle
                '*microsoft.graph.group*' { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'g1'; isAssignableToRole = $true }) } }
                '*administrativeUnit*' { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'a1'; isMemberManagementRestricted = $true }) } }
            }
        }
        $ids = Get-M365TargetRoleIds 'svc@contoso.com'
        $ids | Should -Contain '62e90394-69f5-4237-9190-012177145e10'
        $ids | Should -Contain 'role-assignable-group'
        $ids | Should -Contain 'c0ffee00-0000-0000-0000-00000000c0de'
        $ids | Should -Contain 'restricted-au'
        $t = ConvertFrom-M365Jwt (New-TestToken -Scopes 'UserAuthenticationMethod.ReadWrite.All' -Roles $AuthAdmin)
        $s = Get-M365OperationStatus -Operation 'AuthMethods.Write' -Token $t -CallerRoleIds $t.RoleIds -TargetRoleIds $ids
        $s.Status | Should -Be 'TargetIsPrivileged'
        $s.Message | Should -Match 'Verwaltungseinheit'
        # … auch mit Global Administrator
        $ga = ConvertFrom-M365Jwt (New-TestToken -Scopes 'UserAuthenticationMethod.ReadWrite.All' -Roles $GlobalAdmin)
        (Get-M365OperationStatus -Operation 'AuthMethods.Write' -Token $ga -CallerRoleIds $ga.RoleIds -TargetRoleIds @('restricted-au')).Status | Should -Be 'TargetIsPrivileged'
    }
    It 'Ziel ist privilegiert – mit Privileged Authentication Administrator erlaubt' {
        $t = ConvertFrom-M365Jwt (New-TestToken -Scopes 'UserAuthenticationMethod.ReadWrite.All' -Roles $PrivAuthAdmin)
        (Get-M365OperationStatus -Operation 'AuthMethods.Write' -Token $t -CallerRoleIds $t.RoleIds -TargetRoleIds @($GlobalAdmin)).Status | Should -Be 'Allowed'
    }
}

Describe 'Graph-Fehler' {
    It 'Graph liefert 401' {
        $e = New-GraphError 401 '{"error":{"code":"InvalidAuthenticationToken","message":"Access token has expired."}}' @{ 'request-id' = '11111111-1111-1111-1111-111111111111'; 'client-request-id' = '22222222-2222-2222-2222-222222222222' }
        $d = Resolve-M365GraphError -ErrorRecord $e -Operation 'Sessions.Revoke' -TargetUser 'user@contoso.com'
        $d.Status | Should -Be 'FreshTokenRequired'
        $d.HttpStatus | Should -Be 401
        $d.GraphCode | Should -Be 'InvalidAuthenticationToken'
        $d.RequestId | Should -Be '11111111-1111-1111-1111-111111111111'
        $d.ClientRequestId | Should -Be '22222222-2222-2222-2222-222222222222'
        $d.Endpoint | Should -Match 'revokeSignInSessions'
    }
    It 'Graph liefert 403' {
        $e = New-GraphError 403 '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges to complete the operation."}}'
        $d = Resolve-M365GraphError -ErrorRecord $e -Operation 'AuthMethods.Write' -TargetUser 'ga@contoso.com'
        $d.Status | Should -Be 'ForbiddenByGraph'
        $d.GraphMessage | Should -Be 'Insufficient privileges to complete the operation.'
        $d.RequiredScopes | Should -Be @('UserAuthenticationMethod.ReadWrite.All')
    }
    It 'Graph liefert Claims Challenge' {
        $e = New-GraphError 401 '{"error":{"code":"InvalidAuthenticationToken","message":"Continuous access evaluation resulted in challenge"}}' @{ 'WWW-Authenticate' = 'Bearer realm="", error="insufficient_claims", claims="eyJhY2Nlc3NfdG9rZW4iOnt9fQ=="' }
        (Resolve-M365GraphError -ErrorRecord $e).Status | Should -Be 'ConditionalAccessOrClaimsChallenge'
    }
    It 'erkennt "nicht verbunden" des Graph-SDK' {
        $e = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('Authentication needed. Please call Connect-MgGraph.'), 'Test', 'NotSpecified', $null)
        $d = Resolve-M365GraphError -ErrorRecord $e -Operation 'AuthMethods.Write'
        $d.Status | Should -Be 'FreshTokenRequired'
        $d.Hint | Should -Match 'nicht verbunden'
    }
    It 'gibt kein Token aus' {
        $e = New-GraphError 403 '{"error":{"code":"Authorization_RequestDenied","message":"Denied"}}'
        $d = Resolve-M365GraphError -ErrorRecord $e -Operation 'AuthMethods.Write'
        ($d | ConvertTo-Json -Depth 3) | Should -Not -Match 'eyJ[A-Za-z0-9_-]{20,}\.'
    }
}

Describe 'Inkrementeller Consent und frischer Token' {
    BeforeEach {
        $global:M365.State.Graph = 'connected'
        Set-M365GraphTokenInfo (ConvertFrom-M365Jwt (New-TestToken -Scopes $BaseScopes -Roles $AuthAdmin))
        $script:IssuedTokenScopes = $BaseScopes + 'UserAuthenticationMethod.ReadWrite.All'
        Mock Connect-M365 {
            if ($Fresh) { Set-M365GraphTokenInfo (ConvertFrom-M365Jwt (New-TestToken -Scopes $script:IssuedTokenScopes -Roles $AuthAdmin)) }
            $global:M365.State.Graph = 'connected'
        }
    }
    It 'fordert den fehlenden Scope an, holt einen NEUEN Token und prüft dessen Inhalt' {
        Request-M365GraphScope -Operation 'AuthMethods.Write' -Quiet | Should -BeTrue
        Should -Invoke Connect-M365 -Times 1 -ParameterFilter { $Fresh -and $Force -and $Scopes -contains 'UserAuthenticationMethod.ReadWrite.All' }
        (Get-M365GraphTokenInfo).Scopes | Should -Contain 'UserAuthenticationMethod.ReadWrite.All'
    }
    It 'Token-Cache enthält alten Token: neuer Token ohne Scope wird als Fehlschlag erkannt' {
        $script:IssuedTokenScopes = $BaseScopes      # Broker liefert (noch) den alten Scope-Stand
        Request-M365GraphScope -Operation 'AuthMethods.Write' -Quiet | Should -BeFalse
    }
    It 'Benutzer bricht Consent ab' {
        Mock Connect-M365 { $global:M365.State.Graph = 'error' }
        Request-M365GraphScope -Operation 'AuthMethods.Write' -Quiet | Should -BeFalse
    }
    It 'AuthType UserProvidedAccessToken (extern übergeben) erlaubt keine automatische Neuanforderung' {
        $ext = ConvertFrom-M365Jwt (New-TestToken -Scopes $BaseScopes -Roles $AuthAdmin)
        $ext.Source = 'Extern'
        Set-M365GraphTokenInfo $ext
        Request-M365GraphScope -Operation 'AuthMethods.Write' -Quiet | Should -BeFalse
        Should -Invoke Connect-M365 -Times 0
        (Get-M365OperationStatus -Operation 'AuthMethods.Write' -Token $ext -EscalationSupported $false).Status | Should -Be 'UnsupportedAuthenticationFlow'
    }
    It 'Token vom App-Broker (ebenfalls UserProvidedAccessToken) darf erweitert werden' {
        Test-M365ScopeEscalation (Get-M365GraphTokenInfo) | Should -BeTrue
    }
}

Describe 'Keine Rückstufung auf Lesezugriff' {
    BeforeEach {
        $global:M365.ExtraGraphScopes = @()
        $script:Requested = [System.Collections.Generic.List[string]]::new()
        Mock Get-M365Token { $script:Requested.Add(($ExtraScopes -join ' ')); [pscustomobject]@{ Token = (New-TestToken -Scopes ($BaseScopes + $ExtraScopes) -Roles $AuthAdmin); ExpiresOn = [DateTimeOffset]::UtcNow.AddHours(1) } }
        Mock Connect-M365GraphNative { }
    }
    It 'einmal angeforderte Schreib-Scopes bleiben bei jeder späteren Verbindung erhalten' {
        Connect-M365WithToken Graph @('UserAuthenticationMethod.ReadWrite.All') | Out-Null
        Connect-M365WithToken Graph @() -Fresh | Out-Null          # z. B. stille Erneuerung oder anderes Skript
        Connect-M365WithToken Graph @('User.Read.All') | Out-Null  # engere Anforderung
        $script:Requested | ForEach-Object { $_ | Should -Match 'UserAuthenticationMethod\.ReadWrite\.All' }
        (Get-M365GraphTokenInfo).Scopes | Should -Contain 'UserAuthenticationMethod.ReadWrite.All'
    }
    It 'engeres Connect-MgGraph aus einem Skript ersetzt keine breitere Verbindung' {
        $global:M365.State.Graph = 'connected'
        Set-M365GraphTokenInfo (ConvertFrom-M365Jwt (New-TestToken -Scopes ($BaseScopes + 'UserAuthenticationMethod.ReadWrite.All') -Roles $AuthAdmin))
        Mock Connect-M365 { }
        Connect-MgGraph -Scopes 'User.Read.All'
        Should -Invoke Connect-M365 -Times 0
        (Get-M365GraphTokenInfo).Scopes | Should -Contain 'UserAuthenticationMethod.ReadWrite.All'
    }
    It 'per PIM aktivierte Rolle, die noch nicht im Token steht, verlangt ein frisches Token' {
        $exchangeAdmin = '29232cdf-9323-42fd-ade2-1d097af3e4de'
        $tok = ConvertFrom-M365Jwt (New-TestToken -Scopes ($BaseScopes + 'UserAuthenticationMethod.ReadWrite.All') -Roles $exchangeAdmin)
        $s = Get-M365OperationStatus -Operation 'AuthMethods.Write' -Token $tok -CallerRoleIds $tok.RoleIds -LiveRoleIds @($exchangeAdmin, $AuthAdmin)
        $s.Status | Should -Be 'FreshTokenRequired'
        $s.Message | Should -Match 'PIM'
    }
    It 'holt bei veralteter Rolle automatisch ein frisches Token und führt dann aus' {
        $exchangeAdmin = '29232cdf-9323-42fd-ade2-1d097af3e4de'
        $global:M365.State.Graph = 'connected'
        $global:M365.StrictPreflight = $true
        Set-M365GraphTokenInfo (ConvertFrom-M365Jwt (New-TestToken -Scopes ($BaseScopes + 'UserAuthenticationMethod.ReadWrite.All') -Roles $exchangeAdmin))
        Mock Get-M365LiveRoleIds { @($exchangeAdmin, $AuthAdmin) }
        Mock Get-M365TargetRoleIds { @() }
        Mock Connect-M365 { Set-M365GraphTokenInfo (ConvertFrom-M365Jwt (New-TestToken -Scopes ($BaseScopes + 'UserAuthenticationMethod.ReadWrite.All') -Roles $exchangeAdmin, $AuthAdmin)); $global:M365.State.Graph = 'connected' }
        function global:Test-NativeWrite2 { param([string]$UserId) "ausgeführt für $UserId" }
        function global:Test-ProxyWrite2 { Invoke-M365PrivilegedCommand -Native 'Test-NativeWrite2' -Operation 'AuthMethods.Write' -Arguments $args }
        Test-ProxyWrite2 -UserId 'user@contoso.com' | Should -Be 'ausgeführt für user@contoso.com'
        Should -Invoke Connect-M365 -Times 1 -ParameterFilter { $Fresh -and $Force }
        $global:M365.StrictPreflight = $false
    }
}

Describe 'Token-Anfrage an die App hängt nie' {
    BeforeAll {
        # Nachgebaute App-Seite: Pipe-Server in einem eigenen Thread, Verhalten pro Verbindung steuerbar
        function Start-FakeApp([string]$Name, [string[]]$Behaviour) {
            Start-ThreadJob -ArgumentList $Name, $Behaviour -ScriptBlock {
                param($name, $behaviour)
                foreach ($mode in $behaviour) {
                    $server = [System.IO.Pipes.NamedPipeServerStream]::new($name, 'InOut', 1, 'Byte', 'Asynchronous')
                    $server.WaitForConnection()
                    $r = [System.IO.StreamReader]::new($server); $w = [System.IO.StreamWriter]::new($server); $w.AutoFlush = $true
                    $line = $r.ReadLine()
                    $id = $line.Split('|')[1]
                    switch ($mode) {
                        'silent' { $null = $r.ReadLine() }   # antwortet nie – gibt die Leitung erst frei, wenn der Client trennt (wie die echte App)
                        'heartbeat' { 1..2 | ForEach-Object { $w.WriteLine("res|$id|pending|"); Start-Sleep -Milliseconds 300 }; $w.WriteLine("res|$id|ok|TOKEN-OK|4102444800") }
                        'window' { $w.WriteLine("res|$id|pending|Anmeldefenster für Microsoft Graph ist geöffnet – bitte dort anmelden."); Start-Sleep -Milliseconds 300; $w.WriteLine("res|$id|ok|TOKEN-WIN|4102444800") }
                        'ok' { $w.WriteLine("res|$id|ok|TOKEN-RETRY|4102444800") }
                        'grid' { $w.WriteLine("res|$id|pending|Tabellenfenster ist geöffnet"); $w.WriteLine("res|$id|ok|0,2") }
                    }
                    Start-Sleep -Milliseconds 200
                    $server.Dispose()
                }
            }
        }
    }
    BeforeEach {
        Reset-M365Channel
        $env:M365M_PIPE = 'm365m-test-' + [guid]::NewGuid().ToString('N')
    }
    AfterEach { Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue; Reset-M365Channel; $env:M365M_PIPE = 'm365m-test-pipe' }

    It 'Herzschlag der App, dann Token' {
        $null = Start-FakeApp $env:M365M_PIPE @('heartbeat')
        (Get-M365Token Graph).Token | Should -Be 'TOKEN-OK'
    }
    It 'zeigt an, dass ein Anmeldefenster offen ist' {
        $null = Start-FakeApp $env:M365M_PIPE @('window')
        $out = Get-M365Token Graph 6>&1
        ($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" }) -join ' ' | Should -Match 'Anmeldefenster'
        ($out | Where-Object { $_.Token }).Token | Should -Be 'TOKEN-WIN'
    }
    It 'Tabellenfenster: -PassThru gibt die ausgewählten Zeilen zurück' {
        $null = Start-FakeApp $env:M365M_PIPE @('grid')
        $picked = 'null', 'eins', 'zwei', 'drei' | ForEach-Object { [pscustomobject]@{ Name = $_ } } | Out-GridView -PassThru -Title 'Wahl' 6>$null
        $picked.Name | Should -Be @('null', 'zwei')
    }
    It 'stumme App: neu verbinden, erneut fragen, Token erhalten (statt endlos zu hängen)' {
        $null = Start-FakeApp $env:M365M_PIPE @('silent', 'ok')
        $sw = [Diagnostics.Stopwatch]::StartNew()
        (Get-M365Token Graph).Token | Should -Be 'TOKEN-RETRY'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 60
    }
}

Describe 'Tabellenfenster (Out-GridView)' {
    It 'bereitet Objekte auf: leere Spalten weg, Datum lesbar, Zahlen bleiben Zahlen, Listen als Text' {
        $items = [System.Collections.Generic.List[object]]::new()
        $items.Add([pscustomobject]@{ DisplayName = 'Anna'; Size = 12; Leer = $null; Created = [datetime]'2026-01-02 03:04:05'; Aliases = @('a', 'b') })
        $items.Add([pscustomobject]@{ DisplayName = 'Ben'; Size = 3; Leer = ''; Created = $null; Aliases = @() })
        $d = ConvertTo-M365GridData $items 'Test' | ConvertFrom-Json
        $d.title | Should -Be 'Test'
        $d.columns | Should -Be @('DisplayName', 'Size', 'Created', 'Aliases')
        $d.rows[0][1] | Should -Be 12
        $d.rows[0][1] | Should -BeOfType [long]
        $d.rows[0][2] | Should -Be '2026-01-02 03:04:05'
        $d.rows[0][3] | Should -Be 'a, b'
        $d.rows[1][2] | Should -Be ''
    }
    It 'einfache Werte landen in einer Spalte "Wert"' {
        $items = [System.Collections.Generic.List[object]]::new(); 'x', 'y' | ForEach-Object { $items.Add($_) }
        $d = ConvertTo-M365GridData $items 'T' | ConvertFrom-Json
        $d.columns | Should -Be @('Wert')
        $d.rows.Count | Should -Be 2
        $d.rows[1][0] | Should -Be 'y'
    }
    It 'ohne App: Tabelle im Terminal, -PassThru gibt alles zurück' {
        $pipe = $env:M365M_PIPE; $env:M365M_PIPE = $null
        try { (1, 2, 3 | Out-GridView -PassThru 6>$null).Count | Should -Be 3 } finally { $env:M365M_PIPE = $pipe }
    }
}

Describe 'Durchreichen an Original-Cmdlets' {
    It 'reicht -Schalter:$false, benannte und positionelle Werte korrekt weiter' {
        function global:Test-NativeConnect { param([Parameter(Position = 0)][string]$Organization, [string]$AppId, [switch]$ShowBanner) "org=$Organization app=$AppId banner=$([bool]$ShowBanner)" }
        function global:Test-ConnectProxy { Invoke-M365Native 'Test-NativeConnect' (ConvertFrom-M365Arguments $args) }
        Test-ConnectProxy -AppId 'x' -ShowBanner:$false 'contoso.onmicrosoft.com' | Should -Be 'org=contoso.onmicrosoft.com app=x banner=False'
        Test-ConnectProxy -ShowBanner -AppId 'y' | Should -Be 'org= app=y banner=True'
        Test-ConnectProxy -ShowBanner 'contoso.onmicrosoft.com' | Should -Be 'org=contoso.onmicrosoft.com app= banner=True'
    }
}

Describe 'Preflight vor privilegierten Cmdlets' {
    BeforeEach {
        $global:M365.State.Graph = 'connected'
        $global:M365.StrictPreflight = $false
        Set-M365GraphTokenInfo (ConvertFrom-M365Jwt (New-TestToken -Scopes ($BaseScopes + 'UserAuthenticationMethod.ReadWrite.All') -Roles $AuthAdmin))
        function global:Test-NativeWrite { param([string]$UserId, [string]$PhoneNumber) "ausgeführt für $UserId" }
        # Wie die echten Wrapper: Aufruf über $args eines Funktionsaufrufs
        function global:Test-ProxyWrite { Invoke-M365PrivilegedCommand -Native 'Test-NativeWrite' -Operation 'AuthMethods.Write' -Arguments $args }
    }
    It 'führt bei normalem Zielkonto aus' {
        Mock Get-M365TargetRoleIds { @() }
        Test-ProxyWrite -UserId 'user@contoso.com' -PhoneNumber '+49 1' | Should -Be 'ausgeführt für user@contoso.com'
    }
    It 'blockiert im strengen Modus bei privilegiertem Zielkonto' {
        Mock Get-M365TargetRoleIds { @('62e90394-69f5-4237-9190-012177145e10') }
        $global:M365.StrictPreflight = $true
        $out = $null
        $message = try { $out = Test-ProxyWrite -UserId 'ga@contoso.com'; '' } catch { $_.Exception.Message }
        $out | Should -BeNullOrEmpty                       # Original-Cmdlet wurde nicht aufgerufen
        $message | Should -Match 'Privileged Authentication Administrator'
    }
    It 'fordert fehlenden Write-Scope vor der Ausführung an' {
        Set-M365GraphTokenInfo (ConvertFrom-M365Jwt (New-TestToken -Scopes $BaseScopes -Roles $AuthAdmin))
        Mock Get-M365TargetRoleIds { @() }
        Mock Get-M365ConsentedGraphScopes { $BaseScopes }
        Mock Connect-M365 { Set-M365GraphTokenInfo (ConvertFrom-M365Jwt (New-TestToken -Scopes ($BaseScopes + 'UserAuthenticationMethod.ReadWrite.All') -Roles $AuthAdmin)); $global:M365.State.Graph = 'connected' }
        Test-ProxyWrite -UserId 'user@contoso.com' | Should -Be 'ausgeführt für user@contoso.com'
        Should -Invoke Connect-M365 -Times 1 -ParameterFilter { $Fresh }
    }
}