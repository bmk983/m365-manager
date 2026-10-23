# Benötigt SharePoint-Administrator.
Get-PnPTenantSite |
    Select-Object Title, Url, Template, StorageUsageCurrent, LastContentModifiedDate, Owner |
    Out-GridView -Title 'SharePoint-Websites'
