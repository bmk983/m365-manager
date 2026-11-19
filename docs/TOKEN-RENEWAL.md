# Lange Skripte: Token-Erneuerung und gemeinsame Verbindungen

## Das Problem

Graph und Exchange Online verbinden sich im Terminal mit einem Token aus der Browser-Anmeldung des Profils:

- `Connect-MgGraph -AccessToken …` → `Get-MgContext` zeigt `AuthType = UserProvidedAccessToken`
- `Connect-ExchangeOnline -AccessToken …`

Solche Tokens erneuern die Module **nicht selbst**. Bisher hat die App sie nur erneuert, wenn ein Befehl **an der Eingabezeile** getippt wurde (`PreCommandLookupAction`, `CommandOrigin = Runspace`). Ein Skript, das 60–90 Minuten am Stück lief, bekam deshalb irgendwann nur noch `401 Unauthorized`. `Get-MgContext` zeigte die Verbindung trotzdem weiter an, denn sie bestand ja noch, nur mit einem abgelaufenen Token.

Exchange hat dasselbe Problem, und es fällt sogar weniger auf: Das Modul meldet für übergebene Tokens als Ablauf `DateTimeOffset.MaxValue` und schickt das alte Token einfach weiter.

## Die Lösung: Erneuerung im Hintergrund, Austausch in der bestehenden Verbindung

`Assets/ps/token-renewal.ps1`, gestartet beim ersten Verbinden per Token:

1. Ein **eigener Runspace** prüft alle 30 Sekunden, ob ein per Token verbundener Dienst (Graph, Exchange, Purview) in weniger als **15 Minuten** abläuft.
2. Er holt über eine **eigene Verbindung** zur App ein neues Token. Sie blockiert den Kanal des Terminals nicht, auch nicht, während ein Skript läuft. Die Anfrage geht mit den Optionen `fresh,silent` heraus:
   - Erneuert wird per Refresh-Token oder über die unsichtbare Browser-Sitzung.
   - **Es öffnet sich nie ein Anmeldefenster.**
   - Die Rechte sind dieselben wie bisher, auch zusätzlich angeforderte Graph-Scopes. Neue Berechtigungen werden nicht angefordert.
3. Das neue Token wird **direkt in der bestehenden Verbindung ausgetauscht**, ohne neu zu verbinden:
   - **Graph:** `GraphSession.Instance.InMemoryTokenCache`. Diesen Speicher liest das SDK bei **jeder** Anfrage (`UserProvidedTokenCredential.GetToken` → `ReadTokenData`).
   - **Exchange/Purview:** `ExternalAccessTokenProvider` in `TokenProviderFactory.tokenProviderMap`. Ausgetauscht werden `authorizationHeader` und `context.AccessToken`, danach wird `tokeninfo` verworfen. Die nächste Anfrage baut die Token-Info aus dem neuen Header neu auf.
4. **Schutz:** Ausgetauscht wird nur, wenn das alte und das neue Token zum **selben Konto und Tenant** gehören (`oid`/`tid`) und, bei Exchange, zur selben Zielgruppe (`aud`: Exchange bzw. Purview). Ein Skript, das sich mit einem eigenen Token oder einem anderen Konto verbunden hat, bleibt unangetastet.
5. Verbindet das Terminal während einer laufenden Erneuerung neu oder trennt es, überschreibt die Erneuerung nichts (Generationszähler).
6. **Notlösung:** Klappt die stille Erneuerung nicht, etwa weil Conditional Access eine neue Anmeldung verlangt, verbindet das Terminal **2 Minuten vor Ablauf** auch mitten in einem Skript neu. Dabei kann ein Anmeldefenster erscheinen. Das ist besser als ein Abbruch mit 401.

`Get-M365Status` zeigt je Dienst, wie lange das Token gilt, wann es zuletzt erneuert wurde und ob die letzte Erneuerung gescheitert ist.

### Warum bleibt es bei `UserProvidedAccessToken` statt `Delegated`?

`Get-MgContext` zeigt weiterhin `AuthType = UserProvidedAccessToken`, und das ist bewusst so. `Connect-MgGraph -Scopes …` (AuthType `Delegated`) würde eine **eigene Anmeldung des Graph SDK** auslösen, mit drei Folgen:

- **Eigener Anmeldeweg:** Die Anmeldung läuft über WAM oder den Systembrowser statt über den Browser des Profils. WAM kann stillschweigend das **Windows-Konto** statt des Admin-Kontos verwenden. Genau solche Kontoverwechslungen soll die App verhindern.
- **Zweite Anmeldung:** Je nach Conditional Access ist eine zweite MFA nötig. `-UseDeviceCode` ist in vielen Tenants per Richtlinie gesperrt.
- **Token-Cache außerhalb der App:** Das SDK legt einen eigenen, persistenten Token-Cache unter `%USERPROFILE%\.mg` an. Das widerspricht der portablen Ablage im Datenordner und dem Grundsatz, Refresh-Tokens nur im Arbeitsspeicher zu halten.

Das Ziel „lange Skripte brechen nicht mehr mit 401 ab“ erreicht der Austausch in der bestehenden Verbindung, ohne diese Nachteile. App-only-Anmeldungen (`Connect-MgGraph -ClientId … -CertificateThumbprint …`) reicht das Terminal wie bisher unverändert an das Graph SDK durch. Die erneuert das SDK selbst.

## Exchange: Welche Skripte sehen die Verbindung des Terminals?

Die Verbindung von `Connect-ExchangeOnline` gehört zum **Prozess und zur geladenen Modulversion**.

**Sehen dieselbe Verbindung**, also gleicher Prozess, gleicher Runspace, gleiches Modul:
- Skripte aus dem Skript-Editor (F5/F8, werden dot-gesourct)
- Aufrufe im Terminal mit `.\Skript.ps1`, `& .\Skript.ps1` oder `. .\Skript.ps1`

**Sehen sie nicht**, und das lässt sich technisch nicht ändern:

| Wie das Skript läuft | Warum nicht |
|---|---|
| `pwsh -File …`, `Start-Process pwsh …` | eigener Prozess |
| `Start-Job`, `Start-ThreadJob`, `ForEach-Object -Parallel`, eigene Runspace-Pools | eigener Runspace ohne die Modulsitzung |
| `Import-Module ExchangeOnlineManagement -RequiredVersion …` mit einer anderen Version oder aus einem anderen Pfad | zweite Modulinstanz mit eigenen Verbindungen |

Im letzten Fall warnt das Terminal jetzt, sobald das Skript `Get-ConnectionInformation` aufruft.

**Neu**, damit Skripte die Verbindung finden, statt sich selbst neu anzumelden:

- **`Get-ConnectionInformation`** in einem Skript (auch modul-qualifiziert als `ExchangeOnlineManagement\Get-ConnectionInformation`) verbindet Exchange über die Browser-Anmeldung, falls noch keine Verbindung besteht. Bisher verband sich Exchange erst beim ersten Exchange-Befehl. Ein Skript, das vorher prüfte, fand deshalb nichts und rief selbst `Connect-ExchangeOnline` auf.
- **Modul-qualifizierte Anmeldungen** werden jetzt ebenfalls auf die Browser-Anmeldung umgeleitet, mit denselben Regeln wie die unqualifizierten: `ExchangeOnlineManagement\Connect-ExchangeOnline`, `Microsoft.Graph.Authentication\Connect-MgGraph`, `ExchangeOnlineManagement\Connect-IPPSSession`, `MicrosoftTeams\Connect-MicrosoftTeams` und `PnP.PowerShell\Connect-PnPOnline`. Bisher gingen diese Aufrufe am Abfangen vorbei und öffneten ein eigenes Anmeldefenster.
  - App-Anmeldungen (Zertifikat, Secret, Managed Identity), ein anderes Konto oder ein anderer Tenant gehen weiter unverändert an das Original-Cmdlet.
  - Abschalten mit `Set-M365ConnectOverride $false`.
- Modul-qualifizierte Befehle wie `ExchangeOnlineManagement\Get-Mailbox` lösen jetzt auch das automatische Verbinden und die Erneuerung aus.

## Geändert

| Datei | Änderung |
|---|---|
| `Assets/ps/token-renewal.ps1` | **neu:** Austausch in Graph- und Exchange-Verbindung, Hintergrund-Erneuerung, eigene Kanal-Anfrage |
| `Assets/ps/bootstrap.ps1` | gemeinsamer Erneuerungsstatus, Start/Stopp der Erneuerung, Generationszähler, Hook für Skripte (Notlösung, `Get-ConnectionInformation`, modul-qualifizierte Befehle), `Get-M365Status` mit Ablauf und letzter Erneuerung |
| `Assets/ps/permissions.ps1` | Claims eines im Hintergrund erneuerten Tokens werden übernommen |
| `Terminal/PipeListener.cs` | mehrere gleichzeitige Verbindungen, jede einzeln auf den PowerShell-Prozess geprüft |
| `Services/TokenBroker.cs` | Option `silent`: nie ein Anmeldefenster, stattdessen ein Fehler |
| `Terminal/TerminalView.cs`, `Services/RbacHost.cs` | Optionen als `TokenFlags` |

## Testen

**Automatisch:** `tests/TokenRenewal.Tests.ps1`. Mit den echten Modulen:

```powershell
$env:M365M_TEST_MODULES = '<Datenordner>\modules'
Invoke-Pester tests
```

Ohne diese Variable laufen die Tests, die die Module brauchen, nicht mit.

Die Tests prüfen mit unsignierten Test-Tokens, also ohne Tenant:
- **Graph:** Nach dem Austausch verwendet die Anfragekette des SDK sofort das neue Token. Das gilt auch, wenn der Austausch aus einem anderen Runspace kommt.
- **Exchange:** Header und Token-Info werden ersetzt, Exchange und Purview bleiben getrennt, fremde Konten bleiben unangetastet.
- **Ablauf der Erneuerung:** Anfrage mit `fresh,silent`, kein Überschreiben nach einem Neuverbinden, Fehlerfall.
- **Hooks:** modul-qualifiziertes `Connect-*`, `Get-ConnectionInformation` und die Notlösung.

**Von Hand im Tenant:**

1. Im Terminal: `Invoke-MgGraphRequest -Method GET -Uri 'v1.0/organization?$select=id'`, danach `Get-M365Status`. Die Spalte *Token gültig bis* ist gefüllt.
2. Ein langes Skript im Editor starten (F5), z. B.:
   ```powershell
   1..120 | ForEach-Object {
       $r = Invoke-MgGraphRequest -Method GET -Uri 'v1.0/organization?$select=id'
       '{0:HH:mm} ok {1}' -f (Get-Date), $r.value[0].id
       Start-Sleep -Seconds 60
   }
   ```
   Es muss über **mehr als 90 Minuten** jede Minute „ok“ melden. Danach zeigt `Get-M365Status` im selben Tab in der Spalte *Erneuert* die Uhrzeit der letzten stillen Erneuerung.
3. Exchange genauso, z. B. `Get-EXOMailbox -ResultSize 1` in der Schleife.
4. Skript mit `ExchangeOnlineManagement\Get-ConnectionInformation | Where-Object State -eq 'Connected'`: Es findet die Verbindung des Terminals, und es öffnet sich kein Anmeldefenster.
