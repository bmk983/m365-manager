# Datenschutz-Prüfung: Im Repo (und damit im Download) dürfen keine echten Tenant-, Firmen- oder Personendaten stehen.
# Läuft in CI und vor jedem Release (release.yml führt die Tests vor dem Bauen aus) – ein Treffer stoppt das Release.
#
# Zusätzliche, persönliche Suchbegriffe (Name, Firma, Tenant-Domain, Konto …) gehören in die Datei
# tests/.private-terms.txt (ein Begriff pro Zeile). Sie ist per .gitignore ausgeschlossen und verlässt den PC nie.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    function Find-M365Leak([string]$Pattern, [string[]]$Allow = @(), [switch]$Literal) {
        $hits = foreach ($f in $script:Files) {
            $path = Join-Path $script:Root $f
            if (-not (Test-Path $path -PathType Leaf)) { continue }
            $n = 0
            foreach ($line in [IO.File]::ReadLines($path)) {
                $n++
                $found = if ($Literal) { if ($line.IndexOf($Pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0) { @($Pattern) } }
                         else { [regex]::Matches($line, $Pattern, 'IgnoreCase') | ForEach-Object Value }
                foreach ($v in $found) {
                    if (-not ($Allow | Where-Object { $v -match $_ })) { "${f}:$n  $v" }
                }
            }
        }
        @($hits)
    }
}

Describe 'Keine echten Daten im Repo' {
    BeforeAll {
        Push-Location $script:Root
        try { $script:Files = @(git ls-files) | Where-Object { $_ -notmatch '^src/M365Manager/Assets/(editor/vs/|terminal/(xterm|addon-))' -and $_ -notmatch '\.(ico|png|jpg|gif)$' } }
        finally { Pop-Location }
    }

    It 'nur Beispiel-Tenants (contoso/fabrikam)' {
        Find-M365Leak '[a-z0-9-]+\.onmicrosoft\.(com|de|us)' -Allow '^(contoso|fabrikam|sp)\.' | Should -BeNullOrEmpty
    }

    It 'nur Beispiel-Mailadressen' {
        Find-M365Leak '[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}' `
            -Allow '@(contoso|fabrikam|example)\.', '@domain\.tld$', '@users\.noreply\.github\.com$' | Should -BeNullOrEmpty
    }

    It 'keine Benutzerprofil-Pfade' {
        Find-M365Leak '[A-Z]:[\\/]+Users[\\/]+[^\\/\s''"<>%$]+' -Allow '[\\/]Users[\\/]+(Public|Default)' | Should -BeNullOrEmpty
    }

    It 'keine echten Tokens' {
        # Echte JWTs beginnen mit eyJ... .eyJ...; Test-Tokens werden zur Laufzeit erzeugt.
        Find-M365Leak 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}' | Should -BeNullOrEmpty
        Find-M365Leak '(client_?secret|password)\s*[=:]\s*[''"][^''"$]{8,}[''"]' | Should -BeNullOrEmpty
    }

    It 'keine persönlichen Begriffe aus tests/.private-terms.txt' {
        $file = Join-Path $PSScriptRoot '.private-terms.txt'
        if (-not (Test-Path $file)) { Set-ItResult -Skipped -Because 'tests/.private-terms.txt fehlt (nur lokal)'; return }
        $terms = Get-Content $file -Encoding utf8 | ForEach-Object Trim | Where-Object { $_ -and -not $_.StartsWith('#') }
        $hits = foreach ($t in $terms) { Find-M365Leak $t -Literal }
        # Ausgabe ohne den Begriff selbst, damit er nicht im CI-Log landet
        @($hits | ForEach-Object { ($_ -split '  ')[0] }) | Should -BeNullOrEmpty
    }

    It '.private-terms.txt wird nie eingecheckt' {
        Push-Location $script:Root
        try { git check-ignore -q tests/.private-terms.txt; $LASTEXITCODE | Should -Be 0 } finally { Pop-Location }
    }
}
