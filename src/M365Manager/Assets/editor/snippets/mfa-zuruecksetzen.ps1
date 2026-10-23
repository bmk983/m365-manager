# Ist das Zielkonto selbst Administrator, braucht es "Privileged Authentication Administrator".
# Die Standardmethode lässt sich erst entfernen, wenn sie die letzte ist – ggf. zweimal ausführen.
$upn = 'user@contoso.com'

$methoden = Get-MgUserAuthenticationMethod -UserId $upn |
    Where-Object { $_.AdditionalProperties['@odata.type'] -ne '#microsoft.graph.passwordAuthenticationMethod' } |
    Select-Object Id,
        @{ n = 'Typ'; e = { $_.AdditionalProperties['@odata.type'] -replace '#microsoft.graph.', '' } },
        @{ n = 'Details'; e = { $_.AdditionalProperties['displayName'] ?? $_.AdditionalProperties['phoneNumber'] ?? $_.AdditionalProperties['emailAddress'] } }

$entfernen = $methoden | Out-GridView -Title "Methoden von $upn zum Entfernen auswählen" -PassThru
foreach ($m in $entfernen) {
    switch ($m.Typ) {
        'microsoftAuthenticatorAuthenticationMethod' { Remove-MgUserAuthenticationMicrosoftAuthenticatorMethod -UserId $upn -MicrosoftAuthenticatorAuthenticationMethodId $m.Id }
        'phoneAuthenticationMethod' { Remove-MgUserAuthenticationPhoneMethod -UserId $upn -PhoneAuthenticationMethodId $m.Id }
        'fido2AuthenticationMethod' { Remove-MgUserAuthenticationFido2Method -UserId $upn -Fido2AuthenticationMethodId $m.Id }
        'softwareOathAuthenticationMethod' { Remove-MgUserAuthenticationSoftwareOathMethod -UserId $upn -SoftwareOathAuthenticationMethodId $m.Id }
        'emailAuthenticationMethod' { Remove-MgUserAuthenticationEmailMethod -UserId $upn -EmailAuthenticationMethodId $m.Id }
        'windowsHelloForBusinessAuthenticationMethod' { Remove-MgUserAuthenticationWindowsHelloForBusinessMethod -UserId $upn -WindowsHelloForBusinessAuthenticationMethodId $m.Id }
        'temporaryAccessPassAuthenticationMethod' { Remove-MgUserAuthenticationTemporaryAccessPassMethod -UserId $upn -TemporaryAccessPassAuthenticationMethodId $m.Id }
        default { Write-Warning "Nicht unterstützt: $($m.Typ)"; continue }
    }
    Write-Host "✓ entfernt: $($m.Typ) $($m.Details)" -ForegroundColor Green
}
