# Installiert M365 Manager ohne Setup: kopiert die portable EXE nach %LOCALAPPDATA%\Programs\M365 Manager
# und legt eine Startmenue-Verknuepfung an. Keine Adminrechte, kein Deinstaller-Programm.
#
#   Installieren/Aktualisieren:  irm https://raw.githubusercontent.com/bmk983/m365-manager/main/install.ps1 | iex
#   Entfernen:                   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/bmk983/m365-manager/main/install.ps1))) -Uninstall
#
param([switch]$Uninstall, [switch]$Desktop)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\M365 Manager'
$exe = Join-Path $installDir 'M365Manager.exe'
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'M365 Manager.lnk'
$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'M365 Manager.lnk'

function Test-AppRunning {
    @(Get-Process M365Manager -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }).Count -gt 0
}

if ($Uninstall) {
    if (Test-AppRunning) { throw 'M365 Manager laeuft noch. Bitte zuerst schliessen.' }
    foreach ($link in $startMenu, $desktopLink) { if (Test-Path $link) { [IO.File]::Delete($link) } }
    if (Test-Path $exe) { [IO.File]::Delete($exe) }
    $data = Join-Path $installDir 'M365Manager-Data'
    if (Test-Path $data) {
        $answer = Read-Host 'Auch Profile, Browser-Anmeldungen und PowerShell-Module loeschen? [j/N]'
        if ($answer -match '^(j|y)') { [IO.Directory]::Delete($data, $true) }
    }
    if ((Test-Path $installDir) -and -not (Get-ChildItem $installDir -Force)) { [IO.Directory]::Delete($installDir) }
    Write-Host 'M365 Manager wurde entfernt.' -ForegroundColor Green
    return
}

if (Test-AppRunning) { throw 'M365 Manager laeuft gerade. Bitte zuerst schliessen, dann erneut ausfuehren.' }

$release = Invoke-RestMethod 'https://api.github.com/repos/bmk983/m365-manager/releases/latest' -Headers @{ 'User-Agent' = 'M365Manager-Installer' }
$asset = $release.assets | Where-Object { $_.name -like 'M365Manager-*-portable.exe' } | Select-Object -First 1
if (-not $asset) { throw 'Im neuesten Release wurde keine portable EXE gefunden.' }

New-Item -ItemType Directory -Force $installDir | Out-Null
$download = "$exe.download"
Write-Host "Lade M365 Manager $($release.tag_name) ..."
Invoke-WebRequest $asset.browser_download_url -OutFile $download -UseBasicParsing

# Pruefsumme gegen die von GitHub angegebene vergleichen
if ($asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
    if ((Get-FileHash $download -Algorithm SHA256).Hash -ne $Matches[1]) {
        [IO.File]::Delete($download)
        throw 'Pruefsumme stimmt nicht - abgebrochen.'
    }
    Write-Host 'Pruefsumme OK.'
}
Move-Item $download $exe -Force

$shell = New-Object -ComObject WScript.Shell
foreach ($link in @($startMenu) + $(if ($Desktop) { $desktopLink } else { @() })) {
    $s = $shell.CreateShortcut($link)
    $s.TargetPath = $exe
    $s.WorkingDirectory = $installDir
    $s.Description = 'M365 Manager'
    $s.Save()
}

Write-Host ''
Write-Host "M365 Manager $($release.tag_name) ist bereit: Startmenue -> 'M365 Manager'." -ForegroundColor Green
Write-Host "Ordner: $installDir"