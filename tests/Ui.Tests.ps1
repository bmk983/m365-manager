# Oberfläche (WebView-Seiten): keine leeren Werte an DOM-Aufrufe übergeben.
# append(null)/replaceChildren(null) fügt den Text „null“ ein (so im RBAC-Assistenten passiert).

BeforeAll {
    $script:Node = (Get-Command node -ErrorAction SilentlyContinue).Source
    $script:Scan = Join-Path $PSScriptRoot 'dom-null-scan.js'
    $root = Join-Path $PSScriptRoot '..\src\M365Manager\Assets'
    $script:Files = @(
        Join-Path $root 'rbac\rbac.js'
        Join-Path $root 'editor\editor.js'
    )
}

Describe 'Oberfläche: DOM-Aufrufe ohne null/undefined/false' {
    It 'übergibt an append/replaceChildren/prepend/before/after keine Ausdrücke, die null sein können (außer über nodes())' -Skip:(-not (Get-Command node -ErrorAction SilentlyContinue)) {
        $found = @(& $script:Node $script:Scan @script:Files) |
            Where-Object { $_ -notmatch 'c instanceof Node \? c : document\.createTextNode' }   # el(): filtert vorher selbst
        $found | Should -BeNullOrEmpty
    }
    It 'hat die Hilfsfunktion nodes(), die null/undefined/false herausfiltert' {
        Get-Content $script:Files[0] -Raw | Should -Match 'const nodes = \(\.\.\.xs\) => xs\.flat\(Infinity\)\.filter\(x => x !== null && x !== undefined && x !== false\)'
    }
}
