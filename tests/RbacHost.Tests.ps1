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
    )
    $script:RbacSource = Get-Content (Join-Path $PSScriptRoot '..\src\M365Manager\Assets\ps\rbac-host.ps1') -Raw
    $script:RbacJs = Get-Content (Join-Path $PSScriptRoot '..\src\M365Manager\Assets\rbac\rbac.js') -Raw
    $script:RbacCs = Get-Content (Join-Path $PSScriptRoot '..\src\M365Manager\Services\RbacHost.cs') -Raw
}
AfterAll { Remove-Item $script:Work -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'RBAC-Hintergrund-PowerShell' {
    It 'beantwortet jede Anfrage genau einmal' {
        $script:Replies.Count | Should -Be 8
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
