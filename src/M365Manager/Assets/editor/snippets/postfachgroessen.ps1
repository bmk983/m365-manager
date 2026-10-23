Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox, SharedMailbox |
    Get-EXOMailboxStatistics |
    Select-Object DisplayName, ItemCount,
        @{ n = 'GroesseGB'; e = { [math]::Round(([long]("$($_.TotalItemSize)" -replace '^.*\(([\d.,]+) bytes\).*$', '$1' -replace '[.,]', '')) / 1GB, 2) } },
        LastLogonTime |
    Sort-Object GroesseGB -Descending |
    Out-GridView -Title 'Postfachgrößen'
