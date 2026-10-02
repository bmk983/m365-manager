# M365 Manager · lädt die PowerShell-Module portabel in den Datenordner (kein Install-Module, keine Adminrechte).
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Modules,
    [switch]$Update
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

Import-Module Microsoft.PowerShell.PSResourceGet
New-Item -ItemType Directory -Force -Path $Path | Out-Null

$names = $Modules -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$failed = @()

foreach ($name in $names) {
    $target = Join-Path $Path $name
    $installed = @(Get-ChildItem $target -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)

    if ($installed.Count -and -not $Update) {
        "✓ $name $($installed -join ', ')"
        continue
    }

    try {
        $latest = Find-PSResource -Name $name -Repository PSGallery |
            Sort-Object Version -Descending | Select-Object -First 1
        $version = $latest.Version.ToString()

        if ($installed -contains $version) {
            "✓ $name $version ist aktuell"
            continue
        }

        "↓ $name $version"
        Save-PSResource -Name $name -Version "[$version]" -Path $Path -Repository PSGallery -TrustRepository -SkipDependencyCheck

        foreach ($old in $installed | Where-Object { $_ -ne $version }) {
            Remove-Item (Join-Path $target $old) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        $failed += $name
        Write-Error "${name}: $($_.Exception.Message)" -ErrorAction Continue
    }
}

if ($failed) {
    "✗ Fehlgeschlagen: $($failed -join ', ')"
    exit 1
}
"✓ Alle Module bereit."