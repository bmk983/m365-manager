$sku = Get-MgSubscribedSku -All | Select-Object SkuPartNumber, SkuId, ConsumedUnits |
    Out-GridView -Title 'Lizenz auswählen' -OutputMode Single
if (-not $sku) { return }

Get-MgUser -All -Filter "assignedLicenses/any(x:x/skuId eq $($sku.SkuId))" -ConsistencyLevel eventual -CountVariable anzahl `
    -Property DisplayName, UserPrincipalName, AccountEnabled, Department |
    Select-Object DisplayName, UserPrincipalName, AccountEnabled, Department |
    Out-GridView -Title "Benutzer mit $($sku.SkuPartNumber)"
