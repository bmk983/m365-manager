# M365 Manager

Ein Fenster pro Admin-Konto: **integrierter Edge-Browser** für alle Microsoft-365-Portale plus ein **echtes PowerShell-7-Terminal**, das sich automatisch mit Graph, Exchange, Purview, Teams und SharePoint verbindet. Du musst in Edge nicht mehr zwischen Konten wechseln.

## Download & Installation

**Schnellinstallation**: diesen Befehl in PowerShell ausführen. Er lädt das neueste Setup, prüft die Prüfsumme und installiert ohne Adminrechte:

```powershell
irm https://raw.githubusercontent.com/bmk983/m365-manager/main/install.ps1 | iex
```

**Oder manuell** unter [Releases](https://github.com/bmk983/m365-manager/releases):

- **`M365Manager-Setup-x.y.z.exe`**: Installer. Er installiert nur für dich, ohne Adminrechte, nach `%LOCALAPPDATA%\Programs\M365 Manager`, legt einen Startmenü-Eintrag an, optional ein Desktop-Symbol, und bringt einen Deinstaller mit.
- **`M365Manager-x.y.z-portable.exe`**: Einfach starten, ohne Installation, z. B. vom USB-Stick.

Windows SmartScreen kann beim ersten Start warnen, weil die Datei noch nicht signiert ist („Weitere Informationen“ → „Trotzdem ausführen“).
## Start

Es ist kein Adminrecht nötig.

Beim ersten Start lädt die App einmalig:

- **PowerShell 7** (portable ZIP von GitHub, SHA256-geprüft)
- die **Module** Microsoft.Graph (Auswahl), ExchangeOnlineManagement, MicrosoftTeams und PnP.PowerShell

Alles liegt danach im Ordner `M365Manager-Data` neben der EXE. Kopierst du EXE und Ordner auf einen USB-Stick, läuft die App auch dort. Ist der Ordner neben der EXE nicht beschreibbar, nutzt die App stattdessen `%LOCALAPPDATA%\M365Manager`.

## Profile

Jedes Profil hat:

- einen **eigenen Browser-Speicher** (Cookies, Anmeldung). Die Tenants bleiben so strikt getrennt, und das Windows-Konto wird bewusst nicht für SSO genutzt.
- eine **eigene PowerShell-Sitzung**. Der Graph-Token-Cache gilt nur für den laufenden Prozess.
- einen **UPN**, der auf der Microsoft-Anmeldeseite und bei `Connect-*` vorausgefüllt wird. Kennwort und MFA gibst du nur bei Microsoft selbst ein, die App speichert sie nicht.

Über das Profil-Menü (oben links) kannst du eine **Desktop-Verknüpfung** anlegen, die direkt dieses Profil öffnet (`M365Manager.exe --profile <Id oder Name>`).

## Terminal

Die Dienste verbinden sich **automatisch beim ersten passenden Befehl**:

| Dienst     | Beispiele                                                       |
|------------|-----------------------------------------------------------------|
| Graph      | `Get-MgUser`, `Get-MgGroup`, `Get-MgSecurityIncident`           |
| Exchange   | `Get-Mailbox`, `Get-EXOMailbox`, `Get-DistributionGroup`        |
| Purview    | `Get-DlpCompliancePolicy`, `Get-Label`, `Get-ComplianceSearch`  |
| Teams      | `Get-Team`, `Get-CsOnlineUser`                                  |
| SharePoint | `Get-PnPTenantSite`, `Get-PnPTenant`                            |

Weitere Befehle: `Connect-M365 [Dienst|All]`, `Disconnect-M365`, `Get-M365Status`, `Set-M365AutoConnect $false`, `Install-M365Module <Name>` und `Get-M365Help`.

Die Chips über dem Terminal zeigen den Status (grau = getrennt, gelb = verbindet, grün = verbunden, rot = Fehler). Ein Klick auf einen Chip verbindet den Dienst oder trennt ihn.

**PnP / SharePoint:** PnP.PowerShell braucht pro Tenant eine eigene App-Registrierung. Beim ersten PnP-Befehl bietet das Terminal an, sie anzulegen (`Register-M365PnPApp`). Die App bekommt nur **delegierte** Berechtigungen und hat weder Secret noch Zertifikat. Jede Aktion läuft also mit den Rechten des angemeldeten Admins. Die ClientId wird im Profil gespeichert.

Eigene Erweiterungen kommen in `M365Manager-Data\custom.ps1`. Die Datei wird bei jedem Terminalstart geladen.

## Tastenkürzel

| Kürzel                   | Aktion                                     |
|--------------------------|--------------------------------------------|
| Strg+Ö (US: Strg+`)      | Terminal ein-/ausblenden bzw. fokussieren  |
| Strg+T / Strg+W          | Browser-Tab öffnen / schließen             |
| Strg+L                   | Adresszeile                                |
| Strg+Tab                 | Nächster Browser-Tab                       |
| Strg+Klick auf Portal    | Portal in neuem Tab                        |
| Rechtsklick im Terminal  | Kopieren (bei Auswahl) / Einfügen          |
| Strg + / Strg - im Terminal | Schriftgröße                            |

## Bauen

Voraussetzung ist das .NET 8 SDK.

- `.\publish.ps1` erzeugt `dist\M365Manager.exe` (self-contained, eine Datei).
- `.\publish.ps1 -Version 1.2.0 -Setup` erzeugt zusätzlich den Installer. Inno Setup wird dafür automatisch als NuGet-Paket nach `tools\` geladen.

**Neue Version veröffentlichen:** Einen Tag pushen, z. B. `git tag v1.2.0` und dann `git push origin v1.2.0`. GitHub Actions baut daraufhin App und Setup und legt beides als Release an. Alternativ geht das über *Actions → Release → Run workflow*.

## Technik

- WPF (.NET 8) mit WPF-UI (Fluent/Mica)
- WebView2 (Edge), ein Benutzerdatenordner pro Profil
- Terminal: Windows-Pseudokonsole (ConPTY) + xterm.js
- Rückkanal PowerShell → App über eine Named Pipe (nur für den aktuellen Benutzer)

## Lizenz

[MIT](LICENSE). Enthält [xterm.js](https://github.com/xtermjs/xterm.js) (MIT) und nutzt [WPF-UI](https://github.com/lepoco/wpfui) (MIT).
