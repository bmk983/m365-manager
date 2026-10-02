# Erzeugt die portable EXE unter .\dist\M365Manager.exe
$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'src\M365Manager\M365Manager.csproj'
$dist = Join-Path $PSScriptRoot 'dist'

dotnet publish $project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $dist
if ($LASTEXITCODE -ne 0) { throw "Publish fehlgeschlagen ($LASTEXITCODE)" }

$exe = Get-Item (Join-Path $dist 'M365Manager.exe')
"`n✓ Fertig: $($exe.FullName)  ({0:N0} MB)" -f ($exe.Length / 1MB)