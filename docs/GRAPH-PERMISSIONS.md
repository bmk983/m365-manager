# Graph-Berechtigungen im M365 Manager

## Architektur (Ist-Zustand)

- **Kein MSAL in der App, keine eigene MFA-Oberfläche.** MFA-Methoden und Sessions werden im integrierten Terminal mit den Microsoft-Graph-PowerShell-Cmdlets verwaltet (`New-MgUserAuthenticationPhoneMethod`, `Revoke-MgUserSignInSession` …).
- **Token-Herkunft:** Der Token-Broker der App (`src/M365Manager/Services/TokenBroker.cs`) holt das Token über die Browser-Sitzung des Profils (Authorization Code + PKCE) mit der öffentlichen Client-ID **14d82eec-204b-4c2f-b7e8-296a70dab67e** (Microsoft Graph Command Line Tools) und übergibt es per `Connect-MgGraph -AccessToken`. Deshalb meldet `Get-MgContext` **AuthType = UserProvidedAccessToken**. Da die App das Token selbst ausstellt, **kann sie Scopes inkrementell erweitern**.
- **Ausnahme:** Übergibt ein Skript selbst ein Token (`Connect-MgGraph -AccessToken …`), markiert die App es als *Extern*. Dafür ist keine automatische Erweiterung möglich (`UnsupportedAuthenticationFlow`).
- **Refresh-Tokens** liegen nur im Arbeitsspeicher der App, nichts wird auf die Platte geschrieben.

## Ursache des Problems (behoben)

1. Die Standard-Scopes eines Profils (`AdminProfile.DefaultGraphScopes`) enthalten weder `UserAuthenticationMethod.*` noch `User.RevokeSessions.All`. `UserAuthenticationMethod.Read.All` stand nur im Token, weil es im Tenant früher schon einmal bewilligt wurde. `ReadWrite.All` wurde nie angefordert.
2. Es gab keine Prüfung der **tatsächlichen** Token-Scopes, keinen inkrementellen Consent, keine Rollen- oder Zielkonto-Prüfung und keine strukturierte Fehlerdiagnose.
3. Der Broker hat ein zwischengespeichertes Access Token zurückgegeben, solange es noch über 10 Minuten gültig war. Neu bewilligte Scopes kamen deshalb erst nach Ablauf an.

## Lösung

| Baustein | Datei |
|---|---|
| Zentrale Registry Funktion → Scopes/Rollen/Endpunkt, Token-Claims, Preflight, Fehlerdiagnose | `src/M365Manager/Assets/ps/permissions.ps1` |
| Inkrementeller Consent, frischer Token, Preflight-Wrapper, Diagnoseansicht | `src/M365Manager/Assets/ps/bootstrap.ps1` |
| `fresh` (Cache umgehen) und `reauth` (interaktiv, `prompt=login`) im Broker | `Services/TokenBroker.cs`, `Terminal/TerminalView.cs` |
| Menü am Graph-Chip: anzeigen, anfordern, erneut prüfen, neu authentifizieren | `Views/MainWindow.xaml.cs` |
| Tests | `tests/M365Permissions.Tests.ps1` |

### Ablauf bei einer privilegierten Aktion (z. B. `New-MgUserAuthenticationPhoneMethod`)
1. **Preflight:** Scope im **tatsächlichen** Token (JWT-Claim `scp`), aktive Rolle (Claim `wids`, sonst `/me/transitiveMemberOf`) und Rollen des **Zielkontos** (`/users/{id}/transitiveMemberOf`) werden geprüft.
2. **Scope fehlt:** inkrementeller Consent im Profil-Browser, danach **ausdrücklich ein neues Token** (`fresh`), erneute Prüfung der Scopes **im neuen Token**. Erst dann folgt der Schreibzugriff.
3. **Rolle fehlt oder Ziel ist privilegiert:** verständliche Warnung, z. B. dass Privileged Authentication Administrator nötig ist. Im Standard wird trotzdem an Graph gesendet, denn Graph entscheidet endgültig. Mit `$M365.StrictPreflight = $true` wird stattdessen blockiert.
4. **Graph-Fehler:** HTTP-Status, Graph-Code und -Meldung, request-id, client-request-id, correlation-id, benötigte und vorhandene Scopes, Tenant, Client-ID, Zielbenutzer und Endpunkt werden angezeigt und ohne Tokens ins App-Log geschrieben.

### Preflight-Status
`Allowed` · `MissingGraphScope` · `MissingDirectoryRole` · `TargetIsPrivileged` · `ConsentRequired` · `FreshTokenRequired` · `UnsupportedAuthenticationFlow` · `ForbiddenByGraph` · `ConditionalAccessOrClaimsChallenge` · `UnknownGraphError`

### Registry

| Funktion | Angefordert (Least Privilege) | Im Token akzeptiert | Rollen (laut Microsoft) | Endpunkt |
|---|---|---|---|---|
| Authentifizierungsmethoden lesen | `UserAuthenticationMethod.Read.All` | + `UserAuthenticationMethod.ReadWrite.All` | Authentication Admin, Privileged Authentication Admin, Global Admin, Global Reader, Security Reader/Admin | `GET /v1.0/users/{id}/authentication/methods` |
| Authentifizierungsmethoden verwalten | `UserAuthenticationMethod.ReadWrite.All` | dto. | Authentication Admin (nur Nicht-Admins und bestimmte Rollen), Privileged Authentication Admin, Global Admin | `/v1.0/users/{id}/authentication/…` |
| Sessions widerrufen | `User.RevokeSessions.All` | + `User.ReadWrite.All`, `Directory.ReadWrite.All` | User Admin, Helpdesk Admin, Authentication Admin, Privileged Authentication Admin, Global Admin | `POST /v1.0/users/{id}/revokeSignInSessions` |
| Audit-Logs lesen | `AuditLog.Read.All` | dto. | Reports Reader, Security Reader/Admin, Global Reader, Global Admin | `GET /v1.0/auditLogs/directoryAudits` |

Für „Authentifizierungsmethoden verwalten“ wird der generische Scope angefordert, weil alle Methodentypen über dieselben Cmdlets verwaltet werden.

## Bestehende Scopes: Zuordnung (nichts blind entfernt)

Die Standard-Scopes neuer Profile bleiben aus Kompatibilitätsgründen unverändert. Andere Funktionen wie Auto-Connect, Skripte und Intune hängen davon ab. Die neuen Funktionen fordern ihre Scopes **inkrementell** an und nicht beim Login.

| Funktion | Aktuell im Standard | Minimal sinnvoll | Änderung nötig | Mögliche Auswirkung |
|---|---|---|---|---|
| Benutzer lesen/bearbeiten | `User.ReadWrite.All` | `User.Read.All` (lesen) | nein (optional) | Schreibende Benutzer-Cmdlets bräuchten dann Consent |
| Gruppen | `Group.ReadWrite.All` | `Group.Read.All` | nein (optional) | wie oben |
| Verzeichnis allgemein | `Directory.ReadWrite.All` | `Directory.Read.All` | **empfohlen** | sehr breit; viele Admin-Skripte nutzen es aber implizit |
| Rollen lesen | `RoleManagement.Read.Directory` | dto. | nein | – |
| Organisation/Policies/Apps lesen | `Organization.Read.All`, `Policy.Read.All`, `Application.Read.All` | dto. | nein | – |
| Audit/Reports | `AuditLog.Read.All`, `Reports.Read.All` | dto. | nein | – |
| Intune | `DeviceManagementManagedDevices.ReadWrite.All`, `DeviceManagementConfiguration.Read.All` | `…ManagedDevices.Read.All` (lesen) | nein (optional) | Geräteaktionen bräuchten Consent |
| Defender | `SecurityIncident.Read.All`, `SecurityAlert.Read.All`, `ThreatHunting.Read.All` | dto. | nein | – |
| MFA-Methoden verwalten | – | `UserAuthenticationMethod.ReadWrite.All` | **neu, inkrementell** | Consent beim ersten Schreibzugriff |
| Sessions widerrufen | (über `User.ReadWrite.All`) | `User.RevokeSessions.All` | **neu, inkrementell** | nur angefordert, wenn kein kompatibler Scope im Token ist |

Die Scopes eines Profils lassen sich im Profil-Editor unter **Erweitert → Graph-Berechtigungen** reduzieren. Fehlende Scopes werden dann bei Bedarf angefordert.

## Admin-Consent

`UserAuthenticationMethod.ReadWrite.All` und `User.RevokeSessions.All` sind **admin-pflichtige** delegierte Berechtigungen. Normale Benutzer können ihnen nicht selbst zustimmen. Zustimmen darf eine Rolle, die Admin-Consent für delegierte Microsoft-Graph-Berechtigungen erteilen kann, laut Microsoft z. B. Global Administrator, Privileged Role Administrator, Cloud Application Administrator oder Application Administrator. Tenant-Richtlinien können das einschränken. Der Zustimmungsdialog erscheint im Profil-Browser. Ob „im Namen der Organisation“ zugestimmt wird, entscheidet der Admin dort selbst, die App setzt das **nicht** automatisch.

Ob es geklappt hat, prüft die App am **neu ausgestellten** Token. Fehlt der Scope danach weiterhin, kommt ein entsprechender Hinweis, und eine berechtigte Person muss die Berechtigung für die Enterprise-App **Microsoft Graph Command Line Tools** bewilligen.

## Bedienung

Im Terminal (oder über das Menü am **Graph**-Chip):

```powershell
Get-M365GraphPermissions                       # Diagnose: Account, Tenant, Client-ID, Auth-Typ, Token-Zeiten, Scopes, Rollen, Status je Funktion
Request-M365GraphScope -Missing                # fehlende Berechtigungen anfordern (danach Prüfung des NEUEN Tokens)
Test-M365GraphToken                            # frisches Token holen und erneut prüfen
Connect-M365 Graph -Force -Reauth              # neu authentifizieren (z. B. nach Conditional Access / Claims Challenge)
Test-M365Operation AuthMethods.Write -TargetUser user@contoso.com   # Preflight für ein Zielkonto
Get-M365LastGraphError                         # letzten Graph-Fehler analysieren
```

## „Read only“ trotz Admin-Rolle – Absicherung

**Die App verringert nie Berechtigungen (per Test abgesichert):**
- Graph wird immer mit allen Profil-Scopes **plus** allen bisher zusätzlich angeforderten Scopes angefordert. Die Zusatz-Scopes werden nur erweitert, nie gekürzt.
- Der Token-Cache des Brokers ist pro Scope-Kombination getrennt. Ein Token mit weniger Rechten wird nie für eine Anfrage mit mehr Rechten wiederverwendet.
- Ein `Connect-MgGraph` mit engeren Scopes aus einem Skript ersetzt keine bestehende breitere Verbindung.
- Der Browser des Profils nutzt nie das Windows-Konto, und Silent-Anfragen gehen immer mit dem Profil-Konto.

**Rollenänderungen (z. B. PIM-Aktivierung) werden erkannt:**
- **Terminal:** Fehlt eine benötigte Rolle im Token (`wids`), ist sie aber laut Verzeichnis aktiv, holt die App vor der Aktion automatisch ein frisches Token. `Get-M365GraphPermissions` zeigt „Aktiv, aber noch nicht im Token“ an.
- **Portale (Entra, Admin Center …):** Sie halten ihre Tokens im Seitenspeicher, neue Rollen kommen dort sonst erst nach bis zu einer Stunde an. **Profil-Menü → „Rollen im Browser auffrischen“** leert nur diesen Speicher, nicht die Cookies. Die Anmeldung bleibt, und die Portale holen still neue Tokens mit den aktuellen Rollen.

**Kein App-Problem, aber häufig:** Ist das **Zielkonto selbst Administrator**, darf ein Authentication Administrator dessen Methoden nicht ändern, und das Portal zeigt sie nur lesend an. Dafür ist Privileged Authentication Administrator nötig (`TargetIsPrivileged`).

## Grenzen

- Die Rollen-Matrix für Zielkonten folgt der Microsoft-Dokumentation („Who can perform sensitive actions“). Bei Abweichungen entscheidet Graph, die App warnt nur. Auf Verwaltungseinheiten begrenzte Rollen werden nicht ausgewertet.
- Preflight und automatisches Anfordern gelten für die Funktionen der Registry. Andere Graph-Cmdlets laufen unverändert. Ihre Fehler lassen sich mit `Get-M365LastGraphError` analysieren.
- Für `Invoke-MgGraphRequest` mit eigenen URLs gibt es keinen automatischen Preflight.

## Tests

`pwsh -File tests/run-tests.ps1` (Pester 5 wird bei Bedarf portabel nach `tools/` geladen). Die Tests laufen auch in GitHub Actions vor jedem Release.