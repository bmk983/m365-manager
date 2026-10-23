# Temporary Access Pass muss in den Richtlinien für Authentifizierungsmethoden aktiviert sein.
$upn = 'user@contoso.com'

$tap = New-MgUserAuthenticationTemporaryAccessPassMethod -UserId $upn -BodyParameter @{
    lifetimeInMinutes = 60
    isUsableOnce      = $true
}
"Temporary Access Pass für ${upn}: $($tap.TemporaryAccessPass)  (gültig $($tap.LifetimeInMinutes) Minuten, einmalig)"
