$postfach = 'user@contoso.com'
$benutzer = 'kollege@contoso.com'
$recht    = 'Reviewer'   # AvailabilityOnly, LimitedDetails, Reviewer, Author, Editor

$ordner = (Get-EXOMailboxFolderStatistics -Identity $postfach -FolderScope Calendar | Where-Object FolderType -eq 'Calendar').Name
$id = "${postfach}:\$ordner"
if (Get-MailboxFolderPermission -Identity $id -User $benutzer -ErrorAction SilentlyContinue) {
    Set-MailboxFolderPermission -Identity $id -User $benutzer -AccessRights $recht
}
else {
    Add-MailboxFolderPermission -Identity $id -User $benutzer -AccessRights $recht
}
Get-MailboxFolderPermission -Identity $id
