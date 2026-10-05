# Installiert die neueste Version von M365 Manager (nur fuer den aktuellen Benutzer, ohne Adminrechte).
#
#   irm https://raw.githubusercontent.com/bmk983/m365-manager/main/install.ps1 | iex
#
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$release = Invoke-RestMethod 'https://api.github.com/repos/bmk983/m365-manager/releases/latest' -Headers @{ 'User-Agent' = 'M365Manager-Installer' }
$asset = $release.assets | Where-Object { $_.name -like 'M365Manager-Setup-*.exe' } | Select-Object -First 1
if (-not $asset) { throw 'Im neuesten Release wurde kein Setup gefunden.' }

$file = Join-Path $env:TEMP $asset.name
Write-Host "Lade M365 Manager $($release.tag_name) ..."
Invoke-WebRequest $asset.browser_download_url -OutFile $file -UseBasicParsing

# Pruefsumme gegen die von GitHub angegebene vergleichen
if ($asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
    if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $Matches[1]) {
        [IO.File]::Delete($file)
        throw 'Pruefsumme stimmt nicht - Installation abgebrochen.'
    }
    Write-Host 'Pruefsumme OK.'
}

Write-Host 'Installiere ...'
$setup = Start-Process $file -ArgumentList '/SILENT', '/CURRENTUSER', '/NORESTART' -Wait -PassThru
[IO.File]::Delete($file)
if ($setup.ExitCode -ne 0) { throw "Setup wurde mit Code $($setup.ExitCode) beendet." }

Write-Host ''
Write-Host "M365 Manager $($release.tag_name) ist installiert. Start ueber das Startmenue: 'M365 Manager'." -ForegroundColor Green