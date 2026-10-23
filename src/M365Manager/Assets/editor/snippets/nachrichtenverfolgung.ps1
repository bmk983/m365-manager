# Ältere Exchange-Module: Get-MessageTrace statt Get-MessageTraceV2
Get-MessageTraceV2 -SenderAddress 'absender@contoso.com' -StartDate (Get-Date).AddDays(-2) -EndDate (Get-Date) |
    Select-Object Received, SenderAddress, RecipientAddress, Subject, Status |
    Out-GridView -Title 'Nachrichtenverfolgung'
