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

# Aufwärmen: Befehlsliste aller Module einmal einlesen, damit die erste echte Anfrage schnell ist
$null = TabExpansion2 -inputScript 'Get-Mg' -cursorColumn 6
$out.WriteLine('{"ready":true}')
$out.Flush()

while ($null -ne ($line = [Console]::In.ReadLine())) {
    $id = 0
    try {
        $req = $line.TrimStart([char]0xFEFF) | ConvertFrom-Json
        $id = $req.id
        $script = $utf8.GetString([Convert]::FromBase64String($req.s))
        $result = TabExpansion2 -inputScript $script -cursorColumn ([int]$req.c)
        $matches = @($result.CompletionMatches)
        $items = @($matches | Select-Object -First $limit | ForEach-Object {
            @{ t = $_.CompletionText; l = $_.ListItemText; k = "$($_.ResultType)"; d = $_.ToolTip }
        })
        $response = @{ id = $id; i = $result.ReplacementIndex; n = $result.ReplacementLength; more = $matches.Count -gt $limit; items = $items }
    }
    catch {
        $response = @{ id = $id; error = $_.Exception.Message; items = @() }
    }
    $out.WriteLine(($response | ConvertTo-Json -Compress -Depth 4))
    $out.Flush()
}