$benutzer = 'user@contoso.com'
$rolle    = 'Member'    # oder 'Owner'

$team = Get-Team | Select-Object DisplayName, GroupId, Visibility |
    Out-GridView -Title 'Team auswählen' -OutputMode Single
if ($team) {
    Add-TeamUser -GroupId $team.GroupId -User $benutzer -Role $rolle
    "✓ $benutzer ist jetzt $rolle in $($team.DisplayName)"
}
