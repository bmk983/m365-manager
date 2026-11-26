# Tests der RBAC-Hintergrund-PowerShell (Protokoll, Listen, Fehler, Abbruch beim ersten Fehler).
# Exchange wird nicht angesprochen – die Cmdlets werden durch Attrappen ersetzt.

BeforeAll {
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('m365m-rbac-' + [guid]::NewGuid().ToString('N'))
    Copy-Item (Join-Path $PSScriptRoot '..\src\M365Manager\Assets\ps') -Destination $script:Work -Recurse
    $copy = Join-Path $script:Work 'rbac-host.ps1'
    $fakes = @'
function Use-RbacService([string]$Service) { }
function Get-ManagementScope { [pscustomobject]@{ Name = 'Nur-Einer'; ScopeRestrictionType = 'RecipientScope'; RecipientRoot = $null; RecipientFilter = "MemberOfGroup -eq 'CN=X'"; Exclusive = $false; IsDefault = $false; WhenCreated = [datetime]'2026-01-01' } }
function Get-ManagementRole { }
function New-Thing { 'erster Befehl ok' }
function Fail-Thing { Write-Error 'Exchange sagt nein' }
function Never-Thing { 'darf nicht laufen' }
# Graph (nur lesend) und Exchange für die App-Liste
function Get-M365GraphTokenInfo { [pscustomobject]@{ TenantId = '00000000-0000-0000-0000-0000000000aa' } }
function Invoke-M365GraphGet([string]$Uri) {
    if ($Uri -match "servicePrincipals\(appId='([^']+)'\)") { return [pscustomobject]@{ id = "res-$($Matches[1])"; appRoles = @([pscustomobject]@{ id = 'r1'; value = 'Mail.Read' }) } }
    if ($Uri -match 'res-00000003.*appRoleAssignedTo') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'g1'; principalId = 'sp-mail'; principalDisplayName = 'Mail-App'; appRoleId = 'r1' }) } }
    if ($Uri -match 'appRoleAssignedTo') { return [pscustomobject]@{ value = @() } }
    if ($Uri -match 'appOwnerOrganizationId') {
        return [pscustomobject]@{ value = @(
            [pscustomobject]@{ id = 'sp-new'; appId = 'app-new'; displayName = 'Neue App'; servicePrincipalType = 'Application'; appOwnerOrganizationId = '00000000-0000-0000-0000-0000000000aa' }
            [pscustomobject]@{ id = 'sp-mail'; appId = 'app-mail'; displayName = 'Mail-App'; servicePrincipalType = 'Application'; appOwnerOrganizationId = '00000000-0000-0000-0000-0000000000aa' }
            [pscustomobject]@{ id = 'sp-mi'; appId = 'app-mi'; displayName = 'Identitaet'; servicePrincipalType = 'ManagedIdentity'; appOwnerOrganizationId = '00000000-0000-0000-0000-0000000000aa' }) }
    }
    throw "unerwartete Graph-Anfrage: $Uri"
}
function Get-ServicePrincipal { }
function Get-ManagementRoleAssignment { }
function Get-ApplicationAccessPolicy { }
# Exchange liefert InScope als Text – "False" darf nicht als ja gelten
function Test-ServicePrincipalAuthorization {
    [pscustomobject]@{ RoleName = 'Application Mail.Read'; GrantedPermissions = 'Mail.Read'; AllowedResourceScope = 'App-Postfaecher'; ScopeType = 'CustomRecipientScope'; InScope = 'False' }
    [pscustomobject]@{ RoleName = 'Application Mail.Send'; GrantedPermissions = 'Mail.Send'; AllowedResourceScope = 'App-Postfaecher'; ScopeType = 'CustomRecipientScope'; InScope = 'True' }
    [pscustomobject]@{ RoleName = 'Application Calendars.Read'; GrantedPermissions = 'Calendars.Read'; AllowedResourceScope = 'App-Postfaecher'; ScopeType = 'CustomRecipientScope'; InScope = $false }
}
'@
    $src = [IO.File]::ReadAllText($copy).Replace('# ------------------------------------------------------------------ Schleife', $fakes + "`n# ------------------------------------------------------------------ Schleife")
    [IO.File]::WriteAllText($copy, $src, [Text.UTF8Encoding]::new($true))

    function Invoke-RbacHost([string[]]$Requests) {
        $psi = [Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($a in '-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $script:Work 'rbac-host.ps1')) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
        $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $psi.Environment['M365M_DATA'] = $script:Work
        [void]$psi.Environment.Remove('M365M_PIPE')
        $p = [Diagnostics.Process]::Start($psi)
        foreach ($r in $Requests) { $p.StandardInput.WriteLine($r) }
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        $null = $p.WaitForExit(60000)
        $marker = [char]0x1e + 'M365RBAC '
        @($out -split "`r?`n" | Where-Object { $_.StartsWith($marker) } | ForEach-Object { $_.Substring($marker.Length) })
    }

    $script:Replies = Invoke-RbacHost @(
        '{"id":1,"op":"scopes","args":{}}'
        '{"id":2,"op":"appRoles","args":{}}'
        '{"id":3,"op":"gibtsnicht","args":{}}'
        '{"id":4,"op":"run","script":"New-Thing\nFail-Thing\nNever-Thing"}'
        '{"id":5,"op":"run","script":"New-Thing\nRemove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId x -AppRoleAssignmentId y"}'
        '{"id":6,"op":"run","script":"Connect-M365 Graph -Scopes AppRoleAssignment.ReadWrite.All"}'
        '{"id":7,"op":"run","script":"Invoke-MgGraphRequest DELETE v1.0/servicePrincipals/x"}'
        '{"id":8,"op":"run","script":"New-Thing -Name Firma-MgmtGruppe"}'
        '{"id":9,"op":"apps","args":{}}'
        '{"id":10,"op":"testApp","args":{"identity":"sp-new","resource":"aussen@contoso.com"}}'
    )
    $script:RbacSource = Get-Content (Join-Path $PSScriptRoot '..\src\M365Manager\Assets\ps\rbac-host.ps1') -Raw
    $script:RbacJs = Get-Content (Join-Path $PSScriptRoot '..\src\M365Manager\Assets\rbac\rbac.js') -Raw
    $script:RbacCs = Get-Content (Join-Path $PSScriptRoot '..\src\M365Manager\Services\RbacHost.cs') -Raw
}
AfterAll { Remove-Item $script:Work -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'RBAC-Hintergrund-PowerShell' {
    It 'beantwortet jede Anfrage genau einmal' {
        $script:Replies.Count | Should -Be 10
    }
    It 'listet auch eigene Apps ohne Berechtigungen (frisch angelegt), ohne Doppelte und ohne Managed Identities' {
        $r = $script:Replies[8] | ConvertFrom-Json
        $r.ok | Should -BeTrue
        $names = @($r.data | ForEach-Object displayName)
        $names | Should -Contain 'Neue App'
        $names | Should -Not -Contain 'Identitaet'
        @($names | Where-Object { $_ -eq 'Mail-App' }).Count | Should -Be 1
        $new = $r.data | Where-Object displayName -eq 'Neue App'
        $new.appId | Should -Be 'app-new'
        $new.ownTenant | Should -BeTrue
        @($new.grants).Count | Should -Be 0
        $mail = $r.data | Where-Object displayName -eq 'Mail-App'
        $mail.grants[0].permission | Should -Be 'Mail.Read'
        $mail.appId | Should -Be 'app-mail'
    }
    It 'wertet InScope "False" aus Exchange als nein (nicht als ja)' {
        $r = $script:Replies[9] | ConvertFrom-Json
        $r.ok | Should -BeTrue
        @($r.data | ForEach-Object inScope) | Should -Be @($false, $true, $false)
    }
    It 'macht aus Exchange-Ja/Nein nie [bool] eines Textes' {
        $script:RbacSource | Should -Not -Match '\[bool\]\$(_|r)\.(InScope|Enabled|Exclusive|IsDefault|IsEndUserRole)'
    }
    It 'liefert auch eine einzelne Zeile als Liste' {
        $script:Replies[0] | Should -Match '"data":\[\{'
        ($script:Replies[0] | ConvertFrom-Json).data[0].filter | Should -Be "MemberOfGroup -eq 'CN=X'"
    }
    It 'liefert eine leere Liste als [] (nicht null)' {
        $script:Replies[1] | Should -Match '"data":\[\]'
    }
    It 'meldet unbekannte Anfragen als Fehler' {
        $r = $script:Replies[2] | ConvertFrom-Json
        $r.ok | Should -BeFalse
        $r.error | Should -Match 'Unbekannte Anfrage'
    }
    It 'bricht beim ersten Fehler ab und gibt die Ausgabe bis dahin zurück' {
        $out = ($script:Replies[3] | ConvertFrom-Json).data.output
        $out | Should -Match 'erster Befehl ok'
        $out | Should -Match 'FEHLER: Exchange sagt nein'
        $out | Should -Not -Match 'darf nicht laufen'
    }
}

Describe 'Schutz der Entra-/Graph-Berechtigungen im RBAC-Bereich' {
    It 'führt keine Graph-Befehle aus – auch nicht den Teil davor' {
        foreach ($i in 4, 5, 6) {
            $r = $script:Replies[$i] | ConvertFrom-Json
            $r.ok | Should -BeFalse
            $r.error | Should -Match 'keine Microsoft-Graph-/Entra-Befehle'
            "$($r.data)" | Should -Not -Match 'erster Befehl ok'
        }
    }
    It 'blockiert normale Exchange-Befehle nicht (auch nicht mit "-Mg" im Namen)' {
        $r = $script:Replies[7] | ConvertFrom-Json
        $r.ok | Should -BeTrue
        $r.data.output | Should -Match 'erster Befehl ok'
    }
    It 'hat keine Ersatz-Anmeldung über das Modul (WAM/Windows-Konto)' {
        $script:RbacSource | Should -Match 'function Connect-M365Classic[^{]*\{\s*throw'
    }
    It 'fordert in der Oberfläche keine zusätzlichen Graph-Scopes an und entfernt Entra-Rechte nur über das Portal' {
        $script:RbacJs | Should -Not -Match 'Connect-M365|-Scopes|Remove-Mg|AppRoleAssignment\.ReadWrite'
        $script:RbacJs | Should -Match "t: 'portal'"
    }
    It 'lehnt Token-Anfragen mit zusätzlichen Graph-Scopes auf App-Seite ab' {
        $script:RbacCs | Should -Match 'args\[0\] == "Graph" && !string\.IsNullOrWhiteSpace\(extra\)'
    }
}
