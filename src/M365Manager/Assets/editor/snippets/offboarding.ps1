# Offboarding – bitte jeden Schritt prüfen. Tipp: Zeilen markieren und mit F8 einzeln ausführen.
$upn         = 'user@contoso.com'
$manager     = 'chef@contoso.com'          # bekommt Vollzugriff auf das Postfach
$abwesenheit = 'Diese Person ist nicht mehr im Unternehmen. Bitte wenden Sie sich an chef@contoso.com.'

$user = Get-MgUser -UserId $upn -Property Id, DisplayName, AccountEnabled

# 1. Anmeldung sperren und alle Sitzungen beenden
Update-MgUser -UserId $user.Id -AccountEnabled:$false
Revoke-MgUserSignInSession -UserId $user.Id | Out-Null
Write-Host "✓ $($user.DisplayName) gesperrt, Sitzungen beendet" -ForegroundColor Green

# 2. Postfach: freigegeben, ausgeblendet, Vollzugriff für Vorgesetzte, Abwesenheitsnotiz
Set-Mailbox -Identity $upn -Type Shared -HiddenFromAddressListsEnabled $true
Add-MailboxPermission -Identity $upn -User $manager -AccessRights FullAccess -InheritanceType All -AutoMapping $true | Out-Null
Set-MailboxAutoReplyConfiguration -Identity $upn -AutoReplyState Enabled -InternalMessage $abwesenheit -ExternalMessage $abwesenheit
Write-Host '✓ Postfach umgestellt' -ForegroundColor Green

# 3. Aus Gruppen entfernen (dynamische und lokal synchronisierte Gruppen werden übersprungen)
Get-MgUserMemberOf -UserId $user.Id -All |
    Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' } |
    ForEach-Object {
        $g = Get-MgGroup -GroupId $_.Id -Property Id, DisplayName, GroupTypes, MailEnabled, Mail, OnPremisesSyncEnabled
        if ($g.GroupTypes -contains 'DynamicMembership' -or $g.OnPremisesSyncEnabled) { Write-Host "  übersprungen: $($g.DisplayName)" -ForegroundColor DarkGray; return }
        if ($g.MailEnabled -and $g.GroupTypes -notcontains 'Unified') {
            Remove-DistributionGroupMember -Identity $g.Mail -Member $upn -Confirm:$false -BypassSecurityGroupManagerCheck
        }
        else {
            Remove-MgGroupMemberDirectoryObjectByRef -GroupId $g.Id -DirectoryObjectId $user.Id
        }
        Write-Host "  entfernt aus: $($g.DisplayName)"
    }

# 4. Direkt zugewiesene Lizenzen entfernen (Lizenzen über Gruppen fallen mit Schritt 3 weg)
$skus = @((Get-MgUserLicenseDetail -UserId $user.Id).SkuId)
if ($skus) { Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses $skus | Out-Null }
Write-Host '✓ Fertig' -ForegroundColor Green
