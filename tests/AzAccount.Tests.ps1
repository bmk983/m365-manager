# Connect-AzAccount im Terminal: Tenant und Konto aus der M365-Anmeldung vorausfüllen, ohne WAM.
# Az.Accounts wird durch ein Test-Modul gleichen Namens ersetzt – kein Download, kein Tenant.

BeforeAll {
    $ps = Join-Path $PSScriptRoot '..\src\M365Manager\Assets\ps'
    $env:M365M_PROFILE = 'Test'; $env:M365M_UPN = 'admin@contoso.onmicrosoft.com'; $env:M365M_TENANT = 'contoso.onmicrosoft.com'
    $env:M365M_PIPE = 'm365m-test-' + [guid]::NewGuid().ToString('N')
    $env:M365M_DATA = Join-Path ([IO.Path]::GetTempPath()) ('m365m-az-' + [guid]::NewGuid().ToString('N'))
    $env:M365M_MODULES = Join-Path $env:M365M_DATA 'modules'
    New-Item -ItemType Directory -Force $env:M365M_DATA | Out-Null
    . (Join-Path $ps 'bootstrap.ps1') *> $null
    $script:Hook = $ExecutionContext.InvokeCommand.PreCommandLookupAction
    $ExecutionContext.InvokeCommand.PreCommandLookupAction = $null
    $ExecutionContext.InvokeCommand.CommandNotFoundAction = $null

    $global:AzCalls = [System.Collections.Generic.List[hashtable]]::new()
    $global:AzConfig = [System.Collections.Generic.List[hashtable]]::new()
    # Wie das echte Modul: binäre Cmdlets (Skript-Funktionen würden die Funktion des Terminals überdecken)
    $dll = Join-Path $env:M365M_DATA 'Az.Accounts.dll'
    Add-Type -OutputAssembly $dll -TypeDefinition @'
using System.Collections;
using System.Management.Automation;
public abstract class FakeAzCmdlet : PSCmdlet {
    protected void Record(string list) {
        var h = new Hashtable();
        foreach (var kv in MyInvocation.BoundParameters) h[kv.Key] = kv.Value is SwitchParameter s ? (object)s.IsPresent : kv.Value;
        ((IList)SessionState.PSVariable.GetValue(list)).Add(h);
    }
}
[Cmdlet("Connect", "AzAccount")]
public class FakeConnectAzAccount : FakeAzCmdlet {
    [Parameter][Alias("TenantId")] public string Tenant { get; set; }
    [Parameter] public string AccountId { get; set; }
    [Parameter] public SwitchParameter UseDeviceAuthentication { get; set; }
    [Parameter] public SwitchParameter ServicePrincipal { get; set; }
    [Parameter] public string ApplicationId { get; set; }
    [Parameter] public string CertificateThumbprint { get; set; }
    protected override void EndProcessing() { Record("global:AzCalls"); }
}
[Cmdlet("Update", "AzConfig")]
public class FakeUpdateAzConfig : FakeAzCmdlet {
    [Parameter] public bool EnableLoginByWam { get; set; }
    [Parameter] public string Scope { get; set; }
    protected override void EndProcessing() { Record("global:AzConfig"); }
}
'@
    Import-Module $dll -Global
}

AfterAll {
    Remove-Module Az.Accounts -Force -ErrorAction SilentlyContinue
    Remove-Item $env:M365M_DATA -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Connect-AzAccount mit Angaben der M365-Anmeldung' {
    BeforeEach {
        $global:AzCalls.Clear(); $global:AzConfig.Clear()
        $global:M365.InterceptConnect = $true
        # Graph ist verbunden: Tenant-ID und Konto stehen im Token
        $global:M365.GraphToken = [pscustomobject]@{ TenantId = '00000000-0000-0000-0000-0000000000aa'; Account = 'admin@contoso.onmicrosoft.com'; Scopes = @() }
    }

    It 'füllt Tenant-ID und Konto aus der Graph-Verbindung aus und schaltet WAM nur für den Prozess ab' {
        Connect-AzAccount *> $null
        $global:AzCalls.Count | Should -Be 1
        $global:AzCalls[0].Tenant | Should -Be '00000000-0000-0000-0000-0000000000aa'
        $global:AzCalls[0].AccountId | Should -Be 'admin@contoso.onmicrosoft.com'
        $global:AzConfig[0].EnableLoginByWam | Should -BeFalse
        $global:AzConfig[0].Scope | Should -Be 'Process'
    }

    It 'nimmt ohne Graph-Verbindung Tenant und Konto des Profils' {
        $global:M365.GraphToken = $null
        Mock Get-M365GraphTokenInfo { $null }
        Connect-AzAccount *> $null
        $global:AzCalls[0].Tenant | Should -Be 'contoso.onmicrosoft.com'
        $global:AzCalls[0].AccountId | Should -Be 'admin@contoso.onmicrosoft.com'
    }

    It 'behält einen angegebenen Tenant und ergänzt das Konto, wenn es derselbe Tenant ist' {
        Connect-AzAccount -Tenant '00000000-0000-0000-0000-0000000000aa' *> $null
        $global:AzCalls[0].Tenant | Should -Be '00000000-0000-0000-0000-0000000000aa'
        $global:AzCalls[0].AccountId | Should -Be 'admin@contoso.onmicrosoft.com'
    }

    It 'ergänzt bei einem anderen Tenant kein Konto' {
        Connect-AzAccount -TenantId 'fabrikam.onmicrosoft.com' *> $null
        $global:AzCalls[0].Tenant | Should -Be 'fabrikam.onmicrosoft.com'
        $global:AzCalls[0].ContainsKey('AccountId') | Should -BeFalse
    }

    It 'lässt ein angegebenes Konto und Geräte-Anmeldung unverändert' {
        Connect-AzAccount -AccountId 'other@contoso.onmicrosoft.com' -UseDeviceAuthentication *> $null
        $global:AzCalls[0].AccountId | Should -Be 'other@contoso.onmicrosoft.com'
        $global:AzCalls[0].UseDeviceAuthentication | Should -BeTrue
    }

    It 'reicht App-Anmeldungen unverändert durch' {
        Connect-AzAccount -ServicePrincipal -ApplicationId 'app' -CertificateThumbprint 'x' -Tenant 'fabrikam.onmicrosoft.com' *> $null
        $global:AzCalls[0].ContainsKey('AccountId') | Should -BeFalse
        $global:AzCalls[0].Tenant | Should -Be 'fabrikam.onmicrosoft.com'
        $global:AzConfig.Count | Should -Be 0
    }

    It 'ändert nichts, wenn das Abfangen abgeschaltet ist' {
        $global:M365.InterceptConnect = $false
        Connect-AzAccount *> $null
        $global:AzCalls[0].Count | Should -Be 0
        $global:AzConfig.Count | Should -Be 0
    }

    It 'leitet auch Az.Accounts\Connect-AzAccount aus Skripten um (wie im Connect-Health-Skript)' {
        $ExecutionContext.InvokeCommand.PreCommandLookupAction = $script:Hook
        try { & { Az.Accounts\Connect-AzAccount | Out-Null } *> $null }
        finally { $ExecutionContext.InvokeCommand.PreCommandLookupAction = $null }
        $global:AzCalls.Count | Should -Be 1
        $global:AzCalls[0].AccountId | Should -Be 'admin@contoso.onmicrosoft.com'
    }
}
