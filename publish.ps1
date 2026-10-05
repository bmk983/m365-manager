# Baut die App.
#   .\publish.ps1                      -> dist\M365Manager.exe (portabel)
#   .\publish.ps1 -Version 1.2.0 -Setup -> zusätzlich dist\M365Manager-Setup-1.2.0.exe und eine portable Kopie mit Versionsnummer
param(
    [string]$Version = '1.0.0',
    [switch]$Setup
)
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'src\M365Manager\M365Manager.csproj'
$dist = Join-Path $PSScriptRoot 'dist'

dotnet publish $project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:Version=$Version -o $dist
if ($LASTEXITCODE -ne 0) { throw "Publish fehlgeschlagen ($LASTEXITCODE)" }
$exe = Get-Item (Join-Path $dist 'M365Manager.exe')
"`n✓ App: $($exe.FullName)  ({0:N0} MB)" -f ($exe.Length / 1MB)

if (-not $Setup) { return }

# Inno-Setup-Compiler: installiert, per $env:ISCC, oder als NuGet-Paket nach .\tools laden (keine Installation nötig)
function Get-InnoCompiler {
    $candidates = @($env:ISCC,
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        (Join-Path $PSScriptRoot 'tools\innosetup\tools\ISCC.exe')) | Where-Object { $_ -and (Test-Path $_) }
    if ($candidates) { return @($candidates)[0] }

    $innoVersion = '7.1.0'
    $target = Join-Path $PSScriptRoot 'tools\innosetup'
    $zip = Join-Path $PSScriptRoot "tools\innosetup.$innoVersion.zip"
    New-Item -ItemType Directory -Force (Split-Path $zip) | Out-Null
    Write-Host "Lade Inno Setup $innoVersion (NuGet: Tools.InnoSetup) …"
    Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/tools.innosetup/$innoVersion/tools.innosetup.$innoVersion.nupkg" -OutFile $zip
    Expand-Archive $zip $target -Force
    return (Join-Path $target 'tools\ISCC.exe')
}

$iscc = Get-InnoCompiler
& $iscc "/DAppVersion=$Version" '/Q' (Join-Path $PSScriptRoot 'installer\M365Manager.iss')
if ($LASTEXITCODE -ne 0) { throw "Setup-Build fehlgeschlagen ($LASTEXITCODE)" }

Copy-Item $exe.FullName (Join-Path $dist "M365Manager-$Version-portable.exe") -Force
$setupExe = Get-Item (Join-Path $dist "M365Manager-Setup-$Version.exe")
"✓ Setup: $($setupExe.FullName)  ({0:N0} MB)" -f ($setupExe.Length / 1MB)