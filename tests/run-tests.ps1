# Führt die Pester-Tests aus. Pester 5 wird bei Bedarf portabel nach .\tools geladen (keine Installation).
# Aufruf mit PowerShell 7:  pwsh -File tests\run-tests.ps1
$ErrorActionPreference = 'Stop'
$tools = Join-Path $PSScriptRoot '..\tools'
$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    $local = Get-ChildItem (Join-Path $tools 'Pester') -Filter Pester.psd1 -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $local) {
        New-Item -ItemType Directory -Force $tools | Out-Null
        Save-PSResource -Name Pester -Version '[5.0,6.0)' -Path $tools -Repository PSGallery -TrustRepository
        $local = Get-ChildItem (Join-Path $tools 'Pester') -Filter Pester.psd1 -Recurse | Select-Object -First 1
    }
    Import-Module $local.FullName
}
else { Import-Module $pester.Path }

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $config