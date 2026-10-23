Get-MgSubscribedSku -All |
    Select-Object SkuPartNumber,
        @{ n = 'Gekauft';  e = { $_.PrepaidUnits.Enabled } },
        @{ n = 'Vergeben'; e = { $_.ConsumedUnits } },
        @{ n = 'Frei';     e = { $_.PrepaidUnits.Enabled - $_.ConsumedUnits } } |
    Sort-Object SkuPartNumber |
    Out-GridView -Title 'Lizenzen'
