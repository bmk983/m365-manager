# Baut die portable App (eine EXE, keine Installation nötig).
#   .\publish.ps1                  -> dist\M365Manager.exe
#   .\publish.ps1 -Version 1.2.0   -> zusätzlich dist\M365Manager-1.2.0-portable.exe (für Releases)
param(
    [string]$Version = '1.0.0'
)
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'src\M365Manager\M365Manager.csproj'
$dist = Join-Path $PSScriptRoot 'dist'

dotnet publish $project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:Version=$Version -o $dist
if ($LASTEXITCODE -ne 0) { throw "Publish fehlgeschlagen ($LASTEXITCODE)" }

$exe = Get-Item (Join-Path $dist 'M365Manager.exe')
$versioned = Join-Path $dist "M365Manager-$Version-portable.exe"
Copy-Item $exe.FullName $versioned -Force
"`n✓ App: $($exe.FullName)  ({0:N0} MB)" -f ($exe.Length / 1MB)
"✓ Release-Datei: $versioned"