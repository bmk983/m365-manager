$upn = 'user@contoso.com'

$sku = Get-MgSubscribedSku -All |
    Select-Object SkuPartNumber, SkuId, @{ n = 'Frei'; e = { $_.PrepaidUnits.Enabled - $_.ConsumedUnits } } |
    Out-GridView -Title 'Lizenz auswählen' -OutputMode Single
if (-not $sku) { return }

Update-MgUser -UserId $upn -UsageLocation 'DE'      # Pflicht vor der ersten Lizenz
Set-MgUserLicense -UserId $upn -AddLicenses @(@{ SkuId = $sku.SkuId }) -RemoveLicenses @() | Out-Null
"✓ $($sku.SkuPartNumber) an $upn vergeben"
