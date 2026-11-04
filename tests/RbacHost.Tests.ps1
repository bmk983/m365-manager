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
    )
}
AfterAll { Remove-Item $script:Work -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'RBAC-Hintergrund-PowerShell' {
    It 'beantwortet jede Anfrage genau einmal' {
        $script:Replies.Count | Should -Be 4
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
