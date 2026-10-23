$postfach = 'shared@contoso.com'

$voll = Get-EXOMailboxPermission -Identity $postfach |
    Where-Object { $_.User -notlike 'NT AUTHORITY\*' -and -not $_.Deny } |
    ForEach-Object { [pscustomobject]@{ Wer = $_.User; Recht = ($_.AccessRights -join ', ') } }
$sendAs = Get-EXORecipientPermission -Identity $postfach |
    Where-Object { $_.Trustee -notlike 'NT AUTHORITY\*' } |
    ForEach-Object { [pscustomobject]@{ Wer = $_.Trustee; Recht = ($_.AccessRights -join ', ') } }
@($voll) + @($sendAs) | Out-GridView -Title "Rechte auf $postfach"
