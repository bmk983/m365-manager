Get-MgDeviceManagementManagedDevice -All |
    Select-Object DeviceName, UserPrincipalName, OperatingSystem, OsVersion, ComplianceState, LastSyncDateTime |
    Out-GridView -Title 'Intune-Geräte'
