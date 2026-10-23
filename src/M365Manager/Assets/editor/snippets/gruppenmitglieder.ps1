$gruppe = Get-MgGroup -All -Property Id, DisplayName, Mail |
    Select-Object DisplayName, Mail, Id |
    Out-GridView -Title 'Gruppe auswählen' -OutputMode Single
if (-not $gruppe) { return }

Get-MgGroupMember -GroupId $gruppe.Id -All | ForEach-Object {
    [pscustomobject]@{
        Name = $_.AdditionalProperties['displayName']
        UPN  = $_.AdditionalProperties['userPrincipalName']
        Typ  = $_.AdditionalProperties['@odata.type'] -replace '#microsoft.graph.', ''
    }
} | Out-GridView -Title "Mitglieder von $($gruppe.DisplayName)"
