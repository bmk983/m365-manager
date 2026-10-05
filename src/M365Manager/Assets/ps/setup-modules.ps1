# M365 Manager · lädt die PowerShell-Module portabel in den Datenordner (kein Install-Module, keine Adminrechte).
# Alle Microsoft.Graph-Module werden in exakt derselben Version gehalten – gemischte Versionen lassen sich nicht zusammen laden.
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

function Get-Installed([string]$Name) {
    @(Get-ChildItem (Join-Path $Path $Name) -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
}

$names = @($Modules -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# Bei Updates auch nachträglich installierte Graph-Module mitnehmen, damit alle gleich bleiben.
if ($Update) {
    $names += Get-ChildItem $Path -Directory -Filter 'Microsoft.Graph.*' -ErrorAction SilentlyContinue | ForEach-Object Name
    $names = @($names | Select-Object -Unique)
}

# Ziel-Version für Graph: bei Update die neueste, sonst die bereits installierte (falls vorhanden)
$graphInstalled = Get-Installed 'Microsoft.Graph.Authentication' | Sort-Object { [version]$_ } -Descending | Select-Object -First 1
$graphVersion = if ($Update -or -not $graphInstalled) {
    (Find-PSResource -Name 'Microsoft.Graph.Authentication' -Repository PSGallery | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString()
} else { $graphInstalled }
"Graph-Version: $graphVersion"

$failed = @()
foreach ($name in $names) {
    $installed = Get-Installed $name
    try {
        $version = if ($name -like 'Microsoft.Graph.*') { $graphVersion }
                   elseif ($installed.Count -and -not $Update) { $null }
                   else { (Find-PSResource -Name $name -Repository PSGallery | Sort-Object Version -Descending | Select-Object -First 1).Version.ToString() }

        if (-not $version -or $installed -contains $version) {
            "✓ $name $(if ($version) { $version } else { $installed -join ', ' })"
            continue
        }

        "↓ $name $version"
        Save-PSResource -Name $name -Version "[$version]" -Path $Path -Repository PSGallery -TrustRepository -SkipDependencyCheck

        foreach ($old in $installed | Where-Object { $_ -ne $version }) {
            Remove-Item (Join-Path (Join-Path $Path $name) $old) -Recurse -Force -ErrorAction SilentlyContinue
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