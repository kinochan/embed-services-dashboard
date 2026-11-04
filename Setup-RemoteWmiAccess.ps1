#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Enables inbound WMI/DCOM firewall rules for one management computer and checks local WMI/DCOM readiness.

.DESCRIPTION
Run elevated on the target computer. The required management IP is used to scope the built-in
inbound WMI firewall rules. This script does not change DCOM policy, UAC remote restrictions,
accounts, passwords, WinRM, or Remote Desktop settings.

.PARAMETER ManagementIp
IPv4 or IPv6 address of the computer that will run the dashboard.

.EXAMPLE
.\Setup-RemoteWmiAccess.ps1 -ManagementIp 192.168.1.142

.EXAMPLE
.\Setup-RemoteWmiAccess.ps1 -ManagementIp 192.168.1.142 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ManagementIp
)

$ErrorActionPreference = 'Stop'

$parsedIp = $null
if (-not [System.Net.IPAddress]::TryParse($ManagementIp, [ref]$parsedIp)) {
    throw "ManagementIp must be a literal IPv4 or IPv6 address. Received '$ManagementIp'."
}
$ManagementIp = $parsedIp.ToString()

$dcomPath = 'HKLM:\SOFTWARE\Microsoft\Ole'
$dcomEnabled = $null
try {
    $dcomEnabled = [string](Get-ItemProperty -LiteralPath $dcomPath -Name EnableDCOM -ErrorAction Stop).EnableDCOM
} catch {
    throw "Could not read the DCOM setting from $dcomPath. $($_.Exception.Message)"
}

$wmiService = Get-Service -Name Winmgmt -ErrorAction Stop
if ($wmiService.Status -ne 'Running') {
    if ($PSCmdlet.ShouldProcess('Winmgmt', 'Start the Windows Management Instrumentation service')) {
        Start-Service -Name Winmgmt -ErrorAction Stop
        $wmiService = Get-Service -Name Winmgmt -ErrorAction Stop
    }
}

$localWmiCheck = $false
try {
    Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop | Out-Null
    $localWmiCheck = $true
} catch {
    throw "Local WMI query failed. Check the WMI repository/service before enabling remote access. $($_.Exception.Message)"
}

$wmiRules = @(Get-NetFirewallRule -Name 'WMI-*' -ErrorAction Stop |
    Where-Object { $_.Direction -eq 'Inbound' })
if ($wmiRules.Count -eq 0) {
    throw 'No built-in inbound WMI firewall rules were found. No firewall changes were made.'
}

$applyFirewallChanges = $PSCmdlet.ShouldProcess(
    "$env:COMPUTERNAME inbound WMI firewall rules",
    "Enable and restrict all matching rules to $ManagementIp")
$ruleResults = foreach ($rule in $wmiRules) {
    $addressFilter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
    if ($applyFirewallChanges) {
        Set-NetFirewallAddressFilter -InputObject $addressFilter -RemoteAddress $ManagementIp -ErrorAction Stop
        Set-NetFirewallRule -InputObject $rule -Enabled True -ErrorAction Stop
    }

    [PSCustomObject]@{
        RuleName = $rule.Name
        DisplayName = $rule.DisplayName
        Enabled = if ($applyFirewallChanges) { 'Enabled and scoped' } elseif ($WhatIfPreference) { 'WhatIf - unchanged' } else { [string]$rule.Enabled }
        RemoteAddress = if ($applyFirewallChanges) { $ManagementIp } else { (@($addressFilter.RemoteAddress) -join ', ') }
    }
}

$refreshedService = Get-Service -Name Winmgmt -ErrorAction Stop
$report = [PSCustomObject]@{
    Computer = $env:COMPUTERNAME
    ManagementIp = $ManagementIp
    DcomEnabled = ($dcomEnabled -ieq 'Y' -or $dcomEnabled -ieq 'Yes')
    DcomRegistryValue = $dcomEnabled
    WmiServiceStatus = [string]$refreshedService.Status
    LocalWmiQueryPassed = $localWmiCheck
    FirewallRules = @($ruleResults)
}

$report

if (-not $report.DcomEnabled) {
    Write-Warning "DCOM is disabled (EnableDCOM='$dcomEnabled'). This script does not change that policy; have an administrator review the setting or its governing policy."
}
if ($report.WmiServiceStatus -ne 'Running') {
    Write-Warning "The WMI service is not running. Re-run the script without -WhatIf or have an administrator inspect the service."
}

Write-Verbose "WMI/DCOM setup check finished on $env:COMPUTERNAME."
Write-Verbose "From the dashboard PC, select WMI / DCOM and use management address $ManagementIp for the firewall scope."
Write-Verbose 'The connecting account still needs authorized remote WMI/DCOM permissions. Remote UAC settings were not changed.'
