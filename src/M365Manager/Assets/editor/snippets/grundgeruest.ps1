<#
.SYNOPSIS
    Kurze Beschreibung, was das Skript tut.
.EXAMPLE
    .\MeinSkript.ps1 -Identity user@contoso.com -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$Identity
)

$ErrorActionPreference = 'Stop'
try {
    if ($PSCmdlet.ShouldProcess($Identity, 'Änderung durchführen')) {
        # ...
    }
}
catch {
    Write-Error "Fehler bei ${Identity}: $($_.Exception.Message)"
}
