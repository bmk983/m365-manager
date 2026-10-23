# CSV (z. B. aus Excel, Trennzeichen ;) mit den Spalten: UserPrincipalName;Department
$rows = Import-Csv -Path "$env:USERPROFILE\Desktop\benutzer.csv" -Delimiter ';'

$ergebnis = foreach ($r in $rows) {
    try {
        Update-MgUser -UserId $r.UserPrincipalName -Department $r.Department
        [pscustomobject]@{ Benutzer = $r.UserPrincipalName; Status = 'OK'; Fehler = '' }
    }
    catch {
        [pscustomobject]@{ Benutzer = $r.UserPrincipalName; Status = 'Fehler'; Fehler = $_.Exception.Message }
    }
}
$ergebnis | Out-GridView -Title 'Ergebnis der Massenänderung'
