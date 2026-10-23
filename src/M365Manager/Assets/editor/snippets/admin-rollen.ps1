# Zeigt aktive Rollen (dauerhaft zugewiesen oder per PIM gerade aktiviert).
# Nur berechtigte, nicht aktivierte PIM-Rollen erscheinen hier nicht.
Get-MgDirectoryRole -All | ForEach-Object {
    $rolle = $_
    Get-MgDirectoryRoleMember -DirectoryRoleId $rolle.Id -All | ForEach-Object {
        [pscustomobject]@{
            Rolle = $rolle.DisplayName
            Name  = $_.AdditionalProperties['displayName']
            UPN   = $_.AdditionalProperties['userPrincipalName']
            Typ   = $_.AdditionalProperties['@odata.type'] -replace '#microsoft.graph.', ''
        }
    }
} | Out-GridView -Title 'Aktive Admin-Rollen'
