# M365 Manager · IntelliSense-Helfer für den Skript-Editor.
# Läuft unsichtbar im Hintergrund und liefert Vorschläge über TabExpansion2 – dieselben wie Tab im Terminal.
# Protokoll: eine JSON-Zeile pro Anfrage auf stdin ({ id, s = Skript (Base64), c = Cursor-Offset }), eine JSON-Zeile Antwort auf stdout.

$ErrorActionPreference = 'Continue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8

if ($env:M365M_MODULES -and (Test-Path $env:M365M_MODULES)) {
    $env:PSModulePath = $env:M365M_MODULES + [IO.Path]::PathSeparator + $env:PSModulePath
}

$limit = 300
$out = [Console]::Out
function Write-Diag([string]$Text) { try { [Console]::Error.WriteLine($Text); [Console]::Error.Flush() } catch { } }
$stubDir = if ($env:M365M_DATA) { Join-Path $env:M365M_DATA 'completion' } else { $null }
$stubStamps = @{}

# Bauplan-Dateien der verbundenen Dienste (Exchange, Purview) laden bzw. bei Änderung neu laden.
# Sie enthalten nur Befehlsnamen und Parameter – damit kennt IntelliSense z. B. Get-Recipient.
function Update-Stubs {
    if (-not $stubDir -or -not (Test-Path $stubDir)) { return }
    foreach ($file in Get-ChildItem $stubDir -Filter '*.psm1' -File) {
        if ($stubStamps[$file.FullName] -eq $file.LastWriteTimeUtc) { continue }
        try {
            if ($file.BaseName -in 'exchange', 'purview') { Import-Module ExchangeOnlineManagement -ErrorAction SilentlyContinue }
            $m = Import-Module $file.FullName -Force -DisableNameChecking -ErrorAction Stop -PassThru
            Write-Diag "Bauplan $($file.BaseName): $(@($m.ExportedCommands.Keys).Count) Befehle geladen"
        }
        catch { Write-Diag "Bauplan $($file.BaseName) fehlgeschlagen: $($_.Exception.Message)" }
        $stubStamps[$file.FullName] = $file.LastWriteTimeUtc
    }
}

# "Befehle laden": alle Module des Datenordners importieren und melden, was geklappt hat.
# Exchange zuerst – dessen Anmelde-Bibliothek verträgt sich so am besten mit Graph.
function Invoke-LoadAll([int]$Id) {
    $loaded = @(); $failed = @()
    $names = @(Get-ChildItem $env:M365M_MODULES -Directory -ErrorAction SilentlyContinue | ForEach-Object Name |
        Sort-Object { if ($_ -eq 'ExchangeOnlineManagement') { 0 } elseif ($_ -eq 'Microsoft.Graph.Authentication') { 1 } else { 2 } }, { $_ })
    foreach ($n in $names) {
        try { Import-Module $n -DisableNameChecking -ErrorAction Stop; $loaded += $n }
        catch {
            $msg = $_.Exception.Message
            $failed += @{ name = $n; error = $msg }
            Write-Diag "Modul $n konnte nicht geladen werden: $msg"
        }
    }
    $stubStamps.Clear()
    Update-Stubs
    $stubs = @(Get-ChildItem $stubDir -Filter '*.psm1' -File -ErrorAction SilentlyContinue | ForEach-Object BaseName)
    $count = @(Get-Command -CommandType Cmdlet, Function -ErrorAction SilentlyContinue).Count
    Write-Diag "Befehle laden: $count Befehle, $($loaded.Count) Module ok, $($failed.Count) fehlgeschlagen, Baupläne: $($stubs -join ', ')"
    @{ id = $Id; loaded = $loaded; failed = $failed; stubs = $stubs; commands = $count }
}

# Vorladen im Leerlauf: schwere Module, damit Parameter-Vorschläge sofort kommen.
# Anfragen haben immer Vorrang – zwischen zwei Schritten wird geprüft, ob eine wartet.
$warmUp = [System.Collections.Generic.Queue[scriptblock]]::new()
$warmUp.Enqueue({ $null = TabExpansion2 -inputScript 'Get-Mg' -cursorColumn 6 })
$warmUp.Enqueue({ $null = TabExpansion2 -inputScript 'Get-EXOMailbox -' -cursorColumn 16 })   # Exchange vor Graph laden
$warmUp.Enqueue({ Update-Stubs })
$warmUp.Enqueue({ $null = TabExpansion2 -inputScript 'Get-MgUser -' -cursorColumn 12 })
$warmUp.Enqueue({ $null = TabExpansion2 -inputScript 'Get-MgGroup -' -cursorColumn 13 })

$out.WriteLine('{"ready":true}')
$out.Flush()

# Eigener Reader auf stdin: [Console]::In liest nicht wirklich asynchron.
$reader = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8)
while ($true) {
    $pending = $reader.ReadLineAsync()
    # Leerlauf nutzen, solange keine Anfrage da ist
    while (-not $pending.Wait(40)) {
        if ($warmUp.Count -gt 0) {
            $step = $warmUp.Dequeue()
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try { & $step } catch { Write-Diag "Vorladen fehlgeschlagen ($step): $($_.Exception.Message)" }
            if ($sw.Elapsed.TotalSeconds -gt 3) { Write-Diag ("Vorladen {0:N1} s: {1}" -f $sw.Elapsed.TotalSeconds, "$step".Trim()) }
        }
    }
    $line = $pending.Result
    if ($null -eq $line) { break }

    $id = 0
    try {
        $req = $line.TrimStart([char]0xFEFF) | ConvertFrom-Json
        $id = $req.id
        if ($req.cmd -eq 'loadall') {
            $response = Invoke-LoadAll $id
            $out.WriteLine(($response | ConvertTo-Json -Compress -Depth 4)); $out.Flush()
            continue
        }
        Update-Stubs
        $reqWatch = [Diagnostics.Stopwatch]::StartNew()
        $script = $utf8.GetString([Convert]::FromBase64String($req.s))
        $result = TabExpansion2 -inputScript $script -cursorColumn ([int]$req.c)
        $found = @($result.CompletionMatches)
        $items = @($found | Select-Object -First $limit | ForEach-Object {
            @{ t = $_.CompletionText; l = $_.ListItemText; k = "$($_.ResultType)"; d = $_.ToolTip }
        })
        $response = @{ id = $id; i = $result.ReplacementIndex; n = $result.ReplacementLength; more = $found.Count -gt $limit; items = $items }
        if ($reqWatch.Elapsed.TotalSeconds -gt 3) { Write-Diag ("Langsame Anfrage {0:N1} s: '{1}'" -f $reqWatch.Elapsed.TotalSeconds, $script.Substring([Math]::Max(0, [int]$req.c - 40), [Math]::Min(40, [int]$req.c))) }
    }
    catch {
        Write-Diag "Anfrage fehlgeschlagen: $($_.Exception.Message)"
        $response = @{ id = $id; error = $_.Exception.Message; items = @() }
    }
    $out.WriteLine(($response | ConvertTo-Json -Compress -Depth 4))
    $out.Flush()
}