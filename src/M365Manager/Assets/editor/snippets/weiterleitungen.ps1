# 1. Weiterleitung am Postfach (schnell, ganzer Tenant)
Get-EXOMailbox -ResultSize Unlimited -Properties ForwardingSmtpAddress, ForwardingAddress, DeliverToMailboxAndForward |
    Where-Object { $_.ForwardingSmtpAddress -or $_.ForwardingAddress } |
    Select-Object DisplayName, PrimarySmtpAddress, ForwardingSmtpAddress, ForwardingAddress, DeliverToMailboxAndForward |
    Out-GridView -Title 'Postfächer mit Weiterleitung'

# 2. Posteingangsregeln eines Postfachs, die weiterleiten
$postfach = 'user@contoso.com'
Get-InboxRule -Mailbox $postfach |
    Where-Object { $_.ForwardTo -or $_.ForwardAsAttachmentTo -or $_.RedirectTo } |
    Select-Object Name, Enabled, ForwardTo, ForwardAsAttachmentTo, RedirectTo
