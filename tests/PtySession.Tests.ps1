# Regression: Zweite Terminal-Sitzung im selben App-Prozess stürzte mit 0x80131623 (FailFast) ab,
# weil AttachConsole veraltete Standard-Handles im App-Prozess hinterließ und pwsh sie erbte.

BeforeAll {
    $script:Source = Get-Content (Join-Path $PSScriptRoot '..\src\M365Manager\Terminal\PtySession.cs') -Raw
}

Describe 'Pseudokonsole: Standard-Handles' {
    It 'startet pwsh ohne geerbte Standard-Handles' {
        $script:Source | Should -Match 'dwFlags = Native\.STARTF_USESTDHANDLES'
    }
    It 'stellt die Standard-Handles nach AttachConsole/FreeConsole wieder her' {
        $script:Source | Should -Match '(?s)GetStdHandle\(Native\.STD_OUTPUT_HANDLE\).*AttachConsole.*FreeConsole\(\);\s+Native\.SetStdHandle\(Native\.STD_INPUT_HANDLE, stdIn\)'
    }
}
