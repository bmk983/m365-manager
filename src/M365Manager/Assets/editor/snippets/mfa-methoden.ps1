$upn = 'user@contoso.com'

Get-MgUserAuthenticationMethod -UserId $upn |
    Select-Object Id,
        @{ n = 'Methode'; e = { $_.AdditionalProperties['@odata.type'] -replace '#microsoft.graph.|AuthenticationMethod', '' } },
        @{ n = 'Details'; e = { $_.AdditionalProperties['displayName'] ?? $_.AdditionalProperties['phoneNumber'] ?? $_.AdditionalProperties['emailAddress'] } }
