# Benötigt Entra ID P1 (Anmeldeaktivität) und AuditLog.Read.All.
$tage   = 90
$grenze = (Get-Date).AddDays(-$tage)

Get-MgUser -All -Filter "userType eq 'Guest'" -Property DisplayName, Mail, AccountEnabled, CreatedDateTime, SignInActivity |
    Where-Object { -not $_.SignInActivity.LastSignInDateTime -or $_.SignInActivity.LastSignInDateTime -lt $grenze } |
    Select-Object DisplayName, Mail, AccountEnabled, CreatedDateTime,
        @{ n = 'LetzteAnmeldung'; e = { $_.SignInActivity.LastSignInDateTime } } |
    Out-GridView -Title "Gäste ohne Anmeldung seit $tage Tagen"
