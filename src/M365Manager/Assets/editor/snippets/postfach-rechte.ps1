$postfach = 'shared@contoso.com'
$benutzer = 'user@contoso.com'

Add-MailboxPermission -Identity $postfach -User $benutzer -AccessRights FullAccess -InheritanceType All -AutoMapping $true
Add-RecipientPermission -Identity $postfach -Trustee $benutzer -AccessRights SendAs -Confirm:$false
# Senden im Auftrag statt "Senden als":
# Set-Mailbox -Identity $postfach -GrantSendOnBehalfTo @{ Add = $benutzer }
