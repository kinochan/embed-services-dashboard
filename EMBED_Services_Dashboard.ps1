#Requires -Version 5.1
<#
EMBED Services Dashboard - Enhanced Edition (Optimized)
WPF dashboard for monitoring and controlling EMBED Windows services.
Features: Minimize-to-Tray, Windows Event Viewer, Status History Panel, Service Control Panel, health colors,
Support Snapshots (auto-cleanup), Remote Services control, persistent History logs.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Assemblies
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:SelfPath = [string]$PSCommandPath
if (-not $script:SelfPath) {
    $script:SelfPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}
$hostExeName = [IO.Path]::GetFileNameWithoutExtension($script:SelfPath)
$script:IsPackagedExe = ([IO.Path]::GetExtension($script:SelfPath) -ieq '.exe') -and
    ($hostExeName -notin @('powershell', 'powershell_ise', 'pwsh'))
# Elevation check
$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $script:IsAdmin) {
    if ($script:IsPackagedExe) {
        Start-Process -FilePath $script:SelfPath -Verb RunAs
    } else {
        Start-Process powershell -Verb RunAs -ArgumentList "-File `"$PSCommandPath`""
    }
    exit
}
$script:AppVersion = "2.20"
# Service definitions
$script:ServiceDefs = @(
    [ordered]@{ Name = 'ECSGenSvc';         Display = 'EMBED General Service';      Group = 'Core' }
    [ordered]@{ Name = 'EmbedAPI';          Display = 'EMBED API';                  Group = 'API'  }
    [ordered]@{ Name = 'ECS-KioskService';  Display = 'EMBED Kiosk Service';        Group = 'Core' }
    [ordered]@{ Name = 'EcsReportsService'; Display = 'EMBED Reports Service';      Group = 'Core' }
    [ordered]@{ Name = 'ECSInterface';      Display = 'EMBED Interface Service';    Group = 'Core' }
    [ordered]@{ Name = 'Embed-ESP';         Display = 'EMBED ESP Service';          Group = 'API'  }
    [ordered]@{ Name = 'MSSQLSERVER';       Display = 'SQL Server';                 Group = 'SQL'  }
    [ordered]@{ Name = 'SQLBrowser';        Display = 'SQL Browser';                Group = 'SQL'  }
    [ordered]@{ Name = 'TeamViewer';        Display = 'TeamViewer';                 Group = 'Remote'; MonitorOnly = $true }
    [ordered]@{ Name = 'AnyDesk';           Display = 'AnyDesk';                    Group = 'Remote'; MonitorOnly = $true }
)
# Service Dependency Check
$script:ServiceDependencies = @{
    MSSQLSERVER = @()
    SQLBrowser = @(
        'MSSQLSERVER'
    )
    ECSGenSvc = @(
        'MSSQLSERVER'
    )
    EmbedAPI = @(
        'MSSQLSERVER'
    )
    ECSInterface = @(
        'MSSQLSERVER'
    )
    EcsReportsService = @(
        'MSSQLSERVER'
    )
    'Embed-ESP' = @(
        'EmbedAPI'
    )
    'ECS-KioskService' = @(
        'ECSGenSvc'
    )
}
# Dependency Health Check
function Get-ServiceDependencyState {
    param([string]$ServiceName)
    $deps = $script:ServiceDependencies[$ServiceName]
    if (-not $deps) {
        return @()
    }
    $failed = @()
 foreach ($dep in $deps) {
    $depStatus = Get-SafeServiceStatus $dep
    if ($depStatus.Status -ne 'Running') {
        $failed += [PSCustomObject]@{
            Name   = $dep
            Status = $depStatus.Status
        }
    }
}
    return $failed
}
function Get-ServiceStartOrder {
    $ordered = New-Object System.Collections.Generic.List[string]
    $visited = @{}
    function Add-ServiceRecursive {
        param([string]$ServiceName)
        if ($visited.ContainsKey($ServiceName)) {
            return
        }
        $visited[$ServiceName] = $true
        $deps = $script:ServiceDependencies[$ServiceName]
        if ($deps) {
            foreach ($dep in $deps) {
                Add-ServiceRecursive $dep
            }
        }
        if (-not $ordered.Contains($ServiceName)) {
            $ordered.Add($ServiceName)
        }
    }
    foreach ($svc in $script:ServiceDefs.Name) {
        Add-ServiceRecursive $svc
    }
    return $ordered
}
# Runtime state
$script:HistoryList    = New-Object System.Collections.ObjectModel.ObservableCollection[PSObject]
$script:EventList      = New-Object System.Collections.ObjectModel.ObservableCollection[PSObject]
$script:PreviousStates = @{}
$script:ServiceRows    = @{}
$script:CountdownSecs  = 30
$script:RefreshSecs    = 30     # service refresh (Settings tab, saved)
$script:DeviceSecs     = 60     # device check (Devices tab, saved)
$script:DeviceCountdown = 60
$script:SqlJob         = $null  # background SQL tab check
$script:SqlInfo        = $null
$script:LastSqlCheck   = [datetime]::MinValue
$script:SqlCheckHours  = 24
$script:BackupWarnDays = 1      # last full backup older than this = yellow
$script:BackupRedDays  = 7      # ...older than this = red
$script:ActiveFilter   = 'All'
$script:ServiceCache   = @{}
$script:ServiceResourceMetrics = @{}
$script:PreviousProcessSamples = @{}
$script:DisabledServices = @{}   # services the user switched off (saved to config)
$script:AutoOff = @{}            # services auto-switched off, e.g. not installed (not saved, rechecked each scan)
$script:OfflineEvents = @{}      # service name -> timestamps of recent offline events (for email alerts)
$script:LastAlertSent = @{}      # service name -> when the last alert email went out
$script:ExpectedStops = @{}      # services stopped from this dashboard (not counted as offline events)
$script:Devices = New-Object System.Collections.ObjectModel.ObservableCollection[PSObject]   # saved devices (Devices tab)
$script:DeviceScan = $null       # background device check in progress (runspace + handle)
$script:DiscoverScan = $null     # background network discovery in progress
$script:DiscResults = @()        # everything the last discovery found
$script:DiscList = New-Object System.Collections.ObjectModel.ObservableCollection[PSObject]   # what the Discover panel shows
$script:IgnoredHosts = @{}       # names / IPs the user chose to hide from discovery (saved)
$script:GuruSqlServer = 'localhost'   # SQL Server used to read the GURU reader IPs and for snapshot SQL checks
$script:AutoAddDiscovered = $true     # add newly discovered PCs to the Devices list automatically
$script:UpdateConfig = @{             # GitHub update settings (saved to config.json)
    Repo        = ''                  # owner/name
    Branch      = 'main'
    TokenEnc    = ''                  # optional, only for private repos (encrypted with Windows DPAPI)
    AutoCheck   = $true
    AutoInstall = $false
}
$script:UpdateScan = $null
$script:UpdateInfo = $null
$script:LastUpdateCheck = [datetime]::MinValue
$script:UpdateNotified = ''
$script:SmtpConfig = @{          # email alert settings (saved to config.json)
    Enabled         = $false
    Server          = ''
    Port            = 587
    UseSsl          = $true
    Username        = ''
    PasswordEnc     = ''         # encrypted with Windows DPAPI (this user, this machine)
    From            = ''
    To              = ''
    Threshold       = 3          # offline events...
    WindowMinutes   = 60         # ...within this many minutes triggers an email
    CooldownMinutes = 60         # minimum gap between emails for the same service
}
$script:DataRoot       = 'C:\Program Files (x86)\ECS7\Dashboard'   # snapshots + history logs
$script:EcsDir         = 'C:\Program Files (x86)\ECS7'             # scanned for EMBED versions and logs
$script:SnapshotRoot   = Join-Path $script:DataRoot 'Snapshots'
$script:HistoryDir     = Join-Path $script:DataRoot 'History'
$script:HistoryDays    = 3                                         # daily history CSVs older than this are deleted
$script:SnapshotConfig = @{ KeepCount = 5; MaxAgeDays = 14 }       # saved to config.json
$script:SnapshotJob    = $null
$script:RemoteJob      = $null
$script:RemoteList     = New-Object System.Collections.ObjectModel.ObservableCollection[PSObject]
$script:RemoteServiceDefs = @(
    [ordered]@{ Computer = 'POS1'; Name = 'Spooler'; Display = 'Print Spooler' }
)
$script:DbVerJob       = $null                                     # background database version check
$script:DbVer          = $null                                     # last result (shown in the header badge)
$script:LastDbVerCheck = [datetime]::MinValue
$script:DbVerMinutes   = 1440                                      # re-check every 24 hours (only changes after an update)
$script:SoftwareConfig = @{ StationRoot = 'C:\EMBED\Installers' }  # saved to config.json
$script:Packages       = New-Object System.Collections.ObjectModel.ObservableCollection[PSObject]   # Software tab packages (saved)
$script:SwJob          = $null
$script:SwLog          = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'   # progress lines from the software job
$script:SwTimeoutMin   = 30                                        # give up waiting on an installer after this long
$script:TrayState      = ''
$script:TrayHIcon      = [IntPtr]::Zero
# Start order (stop runs in reverse). CONFIRM this matches EMBED's real dependencies.
$script:StartOrder = Get-ServiceStartOrder
if (-not ('Win32.NativeIcon' -as [type])) {
    Add-Type -Namespace Win32 -Name NativeIcon -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr hIcon);'
}
# CONFIG FILE FUNCTIONS
function Test-Skipped([string]$Name) {
    return ($script:DisabledServices.ContainsKey($Name) -or $script:AutoOff.ContainsKey($Name))
}
function Format-Countdown([int]$Secs) {
    if ($Secs -ge 60) { "{0}m {1}s" -f [int][math]::Floor($Secs / 60), ($Secs % 60) }
    else              { "{0}s" -f $Secs }
}
function Load-Config {
    $path = "C:\Program Files (x86)\ECS7\config.json"
    if (Test-Path $path) {
        try {
            return (Get-Content $path -Raw | ConvertFrom-Json)
        } catch {
            return [PSCustomObject]@{ RefreshSeconds = 30 }
        }
    } else {
        return [PSCustomObject]@{ RefreshSeconds = 30 }
    }
}
function Save-Config {
    param([int]$RefreshSeconds)
    $path = "C:\Program Files (x86)\ECS7\config.json"
    try {
        $dir = Split-Path $path -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        @{
            RefreshSeconds   = $RefreshSeconds
            DeviceSeconds    = $script:DeviceSecs
            DisabledServices = @($script:DisabledServices.Keys)
            Smtp             = $script:SmtpConfig
            IgnoredHosts     = @($script:IgnoredHosts.Keys)
            AutoAddDiscovered = [bool]$script:AutoAddDiscovered
            Update           = $script:UpdateConfig
            SqlServer        = $script:GuruSqlServer
            Snapshot         = $script:SnapshotConfig
            Software         = @{
                StationRoot = $script:SoftwareConfig['StationRoot']
                Packages    = @($script:Packages | ForEach-Object { @{ Name = $_.Name; Installer = $_.Installer; WholeFolder = [bool]$_.WholeFolder; Args = $_.Args } })
            }
            Devices          = @($script:Devices | ForEach-Object {
                @{ Name = $_.Name; LastKnownIP = $_.LastKnownIP; LastSeen = $_.LastSeen }
            })
        } | ConvertTo-Json -Depth 5 | Set-Content $path -Encoding UTF8
    } catch {
        $statusBar.Text = "Config save failed: $($_.Exception.Message)"
    }
}
# XAML
[xml]$XAML = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="EMBED Services Dashboard v$($script:AppVersion)"
    Width="900" Height="950"
    MinWidth="860" MinHeight="520"
    WindowStartupLocation="CenterScreen"
    Background="#1E1E2E"
    Foreground="#CDD6F4"
    FontFamily="Segoe UI"
    FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="BgBase"       Color="#1E1E2E"/>
    <SolidColorBrush x:Key="BgMantle"     Color="#181825"/>
    <SolidColorBrush x:Key="BgCrust"      Color="#11111B"/>
    <SolidColorBrush x:Key="BgCard"       Color="#313244"/>
    <SolidColorBrush x:Key="BgSurface1"   Color="#45475A"/>
    <SolidColorBrush x:Key="TxtBase"      Color="#CDD6F4"/>
    <SolidColorBrush x:Key="TxtMuted"     Color="#6C7086"/>
    <SolidColorBrush x:Key="AccentPurple" Color="#CBA6F7"/>
    <SolidColorBrush x:Key="AccentBlue"   Color="#89B4FA"/>
    <SolidColorBrush x:Key="Green"        Color="#A6E3A1"/>
    <SolidColorBrush x:Key="Red"          Color="#F38BA8"/>
    <SolidColorBrush x:Key="Yellow"       Color="#F9E2AF"/>
    <SolidColorBrush x:Key="Orange"       Color="#FAB387"/>
    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="Foreground"          Value="#CDD6F4"/>
      <Setter Property="Background"          Value="#45475A"/>
      <Setter Property="BorderThickness"     Value="0"/>
      <Setter Property="Padding"             Value="12,5"/>
      <Setter Property="Cursor"              Value="Hand"/>
      <Setter Property="FontSize"            Value="12"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd"
                    Background="{TemplateBinding Background}"
                    CornerRadius="5"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.80"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.60"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnGreen"  TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#3AA6E3A1"/>
      <Setter Property="Foreground" Value="#A6E3A1"/>
    </Style>
    <Style x:Key="BtnRed"    TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#3AF38BA8"/>
      <Setter Property="Foreground" Value="#F38BA8"/>
    </Style>
    <Style x:Key="BtnYellow" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#3AF9E2AF"/>
      <Setter Property="Foreground" Value="#F9E2AF"/>
    </Style>
    <Style x:Key="BtnBlue"   TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#3A89B4FA"/>
      <Setter Property="Foreground" Value="#89B4FA"/>
    </Style>
    <Style x:Key="BtnPurple" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#3ACBA6F7"/>
      <Setter Property="Foreground" Value="#CBA6F7"/>
    </Style>
    <Style x:Key="SwitchToggle" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="track" Width="38" Height="20" CornerRadius="10" Background="#45475A">
              <Ellipse x:Name="thumb" Width="14" Height="14" Fill="#CDD6F4"
                       HorizontalAlignment="Left" Margin="3,0,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#A6E3A1"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="thumb" Property="Margin" Value="0,0,3,0"/>
                <Setter TargetName="thumb" Property="Fill" Value="#1E1E2E"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background"      Value="#1E1E2E"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="0"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground"      Value="#6C7086"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="20,9"/>
      <Setter Property="FontSize"        Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="bd"
                    Background="#181825"
                    BorderThickness="0,0,0,2"
                    BorderBrush="Transparent"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter ContentSource="Header"
                                HorizontalAlignment="Center"
                                VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background"  Value="#1E1E2E"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#CBA6F7"/>
                <Setter Property="Foreground"                   Value="#CBA6F7"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="#CDD6F4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SubTabItem" TargetType="TabItem">
      <Setter Property="Foreground"      Value="#6C7086"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding"         Value="14,5"/>
      <Setter Property="FontSize"        Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="sbd"
                    Background="#1E1E2E"
                    BorderThickness="0,0,0,2"
                    BorderBrush="#313244"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter ContentSource="Header"
                                HorizontalAlignment="Center"
                                VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="sbd" Property="BorderBrush" Value="#89B4FA"/>
                <Setter Property="Foreground" Value="#89B4FA"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="#CDD6F4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background"      Value="#181825"/>
      <Setter Property="Foreground"      Value="#CDD6F4"/>
      <Setter Property="CaretBrush"      Value="#CDD6F4"/>
      <Setter Property="BorderBrush"     Value="#45475A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding"         Value="6,4"/>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Background"      Value="#181825"/>
      <Setter Property="Foreground"      Value="#CDD6F4"/>
      <Setter Property="CaretBrush"      Value="#CDD6F4"/>
      <Setter Property="BorderBrush"     Value="#45475A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding"         Value="6,4"/>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="#313244"/>
      <Setter Property="Width"      Value="5"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="Background"               Value="Transparent"/>
      <Setter Property="Foreground"               Value="#CDD6F4"/>
      <Setter Property="BorderThickness"          Value="0"/>
      <Setter Property="GridLinesVisibility"      Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#313244"/>
      <Setter Property="RowBackground"            Value="Transparent"/>
      <Setter Property="AlternatingRowBackground" Value="#22FFFFFF"/>
      <Setter Property="ColumnHeaderHeight"       Value="34"/>
      <Setter Property="AutoGenerateColumns"      Value="False"/>
      <Setter Property="IsReadOnly"               Value="True"/>
      <Setter Property="SelectionMode"            Value="Single"/>
      <Setter Property="SelectionUnit"            Value="FullRow"/>
      <Setter Property="CanUserResizeRows"        Value="False"/>
      <Setter Property="CanUserReorderColumns"    Value="False"/>
      <Setter Property="HeadersVisibility"        Value="Column"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background"      Value="#181825"/>
      <Setter Property="Foreground"      Value="#CBA6F7"/>
      <Setter Property="FontWeight"      Value="SemiBold"/>
      <Setter Property="Padding"         Value="12,0"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Height"          Value="34"/>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="Transparent"/>
      <Style.Triggers>
        <Trigger Property="IsSelected"  Value="True">
          <Setter Property="Background" Value="#45475A"/>
        </Trigger>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#313244"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="Padding"         Value="0"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background"      Value="Transparent"/>
      <Setter Property="Foreground"      Value="#CDD6F4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Padding="12,6" Background="{TemplateBinding Background}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="Transparent"/>
          <Setter Property="Foreground" Value="#CDD6F4"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="54"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="30"/>
    </Grid.RowDefinitions>
    <!-- HEADER -->
    <Border Grid.Row="0" Background="#181825">
      <Grid Margin="16,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse Width="10" Height="10" Fill="#CBA6F7" Margin="0,0,8,0"/>
          <TextBlock Text="EMBED" FontSize="17" FontWeight="Bold"
                     Foreground="#CBA6F7" VerticalAlignment="Center"/>
          <TextBlock Text=" Services Dashboard v$script:AppVersion" FontSize="17" FontWeight="Light"
                     Foreground="#CDD6F4" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal"
                    HorizontalAlignment="Center" VerticalAlignment="Center">
          <Border Background="#313244" CornerRadius="12" Padding="12,4" Margin="10,0,10,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Refresh in " Foreground="#6C7086" FontSize="12" VerticalAlignment="Center"/>
              <TextBlock x:Name="txtCountdown" Text="30s"
                         Foreground="#CBA6F7" FontSize="12" FontWeight="SemiBold" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Border x:Name="dbBadge" Background="#30CBA6F7" CornerRadius="12" Padding="12,4" Margin="0,0,10,0"
                  VerticalAlignment="Center" Cursor="Hand" ToolTip="Checking database version...">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="DB " Foreground="#6C7086" FontSize="12" VerticalAlignment="Center"/>
              <TextBlock x:Name="txtDbVer" Text="checking..." Foreground="#CBA6F7" FontSize="13" FontWeight="Bold" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <Border x:Name="adminBadge" Background="#30A6E3A1" CornerRadius="12"
                  Padding="12,4" Margin="0,0,10,0" Visibility="Collapsed">
            <TextBlock Text="Administrator" Foreground="#A6E3A1" FontSize="12"/>
          </Border>
          <Border x:Name="nonAdminBadge" Background="#30F9E2AF" CornerRadius="12"
                  Padding="12,4" Visibility="Collapsed">
            <TextBlock Text="Read-Only Mode" Foreground="#F9E2AF" FontSize="12"/>
          </Border>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="btnSnapshot"     Content="📦  Snapshot"      Style="{StaticResource BtnPurple}" Margin="0,0,6,0"
                  ToolTip="Collect logs, errors and system info into a zip for the ticket"/>
          <Button x:Name="btnRefresh"      Content="↻  Refresh"       Style="{StaticResource BtnBase}"   Margin="0,0,6,0"/>
          <Button x:Name="btnClearHistory" Content="🗑  Clear History" Style="{StaticResource BtnBase}"/>
        </StackPanel>
      </Grid>
    </Border>
    <!-- TABS -->
    <TabControl Grid.Row="1" x:Name="MainTabs">
      <!-- Services (History and Summary are sub-tabs) -->
      <TabItem Header="  Services  ">
        <TabControl x:Name="ServiceSubTabs">
          <TabItem Header="Services" Style="{StaticResource SubTabItem}">
            <Grid Background="#1E1E2E">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <Border Grid.Row="0" Background="#181825" Padding="14,8">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="Group:" Foreground="#6C7086"
                               VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <Button x:Name="btnFilterAll"    Content="All"    Style="{StaticResource BtnPurple}" Margin="0,0,4,0"/>
                    <Button x:Name="btnFilterApi"    Content="API"    Style="{StaticResource BtnBase}"   Margin="0,0,4,0"/>
                    <Button x:Name="btnFilterCore"   Content="Core"   Style="{StaticResource BtnBase}"   Margin="0,0,4,0"/>
                    <Button x:Name="btnFilterSQL"    Content="SQL"    Style="{StaticResource BtnBase}"   Margin="0,0,4,0"/>
                    <Button x:Name="btnFilterRemote" Content="Remote" Style="{StaticResource BtnBase}"/>
                  </StackPanel>
                  <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button x:Name="btnStartAll"   Content="▶  Start All"   Style="{StaticResource BtnGreen}"  Margin="0,0,6,0"/>
                    <Button x:Name="btnStopAll"    Content="■  Stop All"    Style="{StaticResource BtnRed}"    Margin="0,0,6,0"/>
                    <Button x:Name="btnRestartAll" Content="↺  Restart All" Style="{StaticResource BtnYellow}"/>
                  </StackPanel>
                </Grid>
              </Border>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="ServicePanel" Margin="12,10,12,10"/>
              </ScrollViewer>
            </Grid>
          </TabItem>
          <TabItem Header="History" Style="{StaticResource SubTabItem}">
            <Grid Background="#1E1E2E">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <Border Grid.Row="0" Background="#181825" Padding="16,9">
                <TextBlock Foreground="#6C7086" FontSize="12"
                           Text="Timestamped log of every service state change — most recent first"/>
              </Border>
              <DataGrid x:Name="HistoryGrid" Grid.Row="1" Margin="12,8,12,8"
                        ItemsSource="{Binding}">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Time"    Binding="{Binding Time}"        Width="155"/>
                  <DataGridTextColumn Header="Service" Binding="{Binding ServiceName}" Width="*"/>
                  <DataGridTextColumn Header="Group"   Binding="{Binding Group}"       Width="80"/>
                  <DataGridTextColumn Header="Was"     Binding="{Binding OldStatus}"   Width="110"/>
                  <DataGridTextColumn Header="Now"     Binding="{Binding NewStatus}"   Width="110"/>
                  <DataGridTextColumn Header="Note"    Binding="{Binding Note}"        Width="200"/>
                </DataGrid.Columns>
              </DataGrid>
            </Grid>
          </TabItem>
                     <!-- Events -->
      <TabItem Header="  Events  " Style="{StaticResource SubTabItem}">
        <Grid Background="#1E1E2E">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <!-- Header -->
          <Border Grid.Row="0"
                  Background="#181825"
                  Padding="16,9">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock
                  Grid.Column="0"
                  Foreground="#6C7086"
                  FontSize="12"
                  VerticalAlignment="Center"
                  Text="Windows Event Viewer entries related to monitored services" />
              <StackPanel Grid.Column="1"
                          Orientation="Horizontal">
                <Button x:Name="btnRefreshEvents"
                        Content="↻ Refresh Events"
                        Style="{StaticResource BtnBase}"
                        Margin="0,0,6,0"/>
                <Button x:Name="btnClearEvents"
                        Content="🗑 Clear View"
                        Style="{StaticResource BtnBase}"/>
              </StackPanel>
            </Grid>
          </Border>
          <!-- Event Grid -->
          <DataGrid
              x:Name="EventsGrid"
              Grid.Row="1"
              Margin="12,8,12,8"
              ItemsSource="{Binding}">
            <DataGrid.Columns>
              <DataGridTextColumn
                  Header="Time"
                  Binding="{Binding Time}"
                  Width="155" />
              <DataGridTextColumn
                  Header="Level"
                  Binding="{Binding Level}"
                  Width="90" />
              <DataGridTextColumn
                  Header="Event ID"
                  Binding="{Binding EventId}"
                  Width="90" />
              <DataGridTextColumn
                  Header="Source"
                  Binding="{Binding Source}"
                  Width="170" />
              <DataGridTextColumn
                  Header="Service"
                  Binding="{Binding Service}"
                  Width="160" />
              <DataGridTextColumn
                  Header="Message"
                  Binding="{Binding Message}"
                  Width="*" />
            </DataGrid.Columns>
          </DataGrid>
        </Grid>
      </TabItem>
          <TabItem Header="Summary" Style="{StaticResource SubTabItem}">
            <ScrollViewer Background="#1E1E2E" VerticalScrollBarVisibility="Auto">
              <StackPanel Margin="20,16,20,20">
                <Grid Margin="0,0,0,14">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/>
                  </Grid.ColumnDefinitions>
                  <Border Grid.Column="0" Background="#313244" CornerRadius="8" Padding="16" Margin="0,0,8,0">
                    <StackPanel>
                      <TextBlock Text="RUNNING"  Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                      <TextBlock x:Name="statRunning" Text="—" Foreground="#A6E3A1" FontSize="38" FontWeight="Bold"/>
                      <TextBlock Text="services" Foreground="#6C7086" FontSize="10"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="1" Background="#313244" CornerRadius="8" Padding="16" Margin="0,0,8,0">
                    <StackPanel>
                      <TextBlock Text="STOPPED"  Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                      <TextBlock x:Name="statStopped" Text="—" Foreground="#F38BA8" FontSize="38" FontWeight="Bold"/>
                      <TextBlock Text="services" Foreground="#6C7086" FontSize="10"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="2" Background="#313244" CornerRadius="8" Padding="16" Margin="0,0,8,0">
                    <StackPanel>
                      <TextBlock Text="OTHER"    Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                      <TextBlock x:Name="statOther" Text="—" Foreground="#F9E2AF" FontSize="38" FontWeight="Bold"/>
                      <TextBlock Text="services" Foreground="#6C7086" FontSize="10"/>
                    </StackPanel>
                  </Border>
                  <Border Grid.Column="3" Background="#313244" CornerRadius="8" Padding="16">
                    <StackPanel>
                      <TextBlock Text="EVENTS"   Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                      <TextBlock x:Name="statEvents" Text="—" Foreground="#CBA6F7" FontSize="38" FontWeight="Bold"/>
                      <TextBlock Text="logged"   Foreground="#6C7086" FontSize="10"/>
                    </StackPanel>
                  </Border>
                </Grid>
                <Border Background="#313244" CornerRadius="8" Padding="18" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="GROUP HEALTH" Foreground="#CBA6F7" FontSize="11"
                               FontWeight="SemiBold" Margin="0,0,0,12"/>
                    <ItemsControl x:Name="GroupHealthPanel"/>
                  </StackPanel>
                </Border>
                <Border Background="#313244" CornerRadius="8" Padding="18">
                  <StackPanel>
                    <TextBlock Text="LAST SCAN" Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                    <TextBlock x:Name="statLastScan" Text="—"
                               Foreground="#CDD6F4" FontSize="14" Margin="0,5,0,0"/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>
          </TabItem>
        </TabControl>
      </TabItem>
      <!-- SQL -->
      <TabItem Header="  SQL  " x:Name="tabSql">
        <Grid Background="#1E1E2E">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" Background="#181825" Padding="16,9">
            <Grid>
              <TextBlock x:Name="txtSqlStatus" Foreground="#6C7086" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,200,0"
                         Text="Read-only view of the EMBED database. Refreshes when you open this tab and every 24 hours."/>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="btnSqlCopy"    Content="Copy"       Style="{StaticResource BtnBase}" Margin="0,0,6,0" ToolTip="Copy everything on this tab for a ticket"/>
                <Button x:Name="btnSqlRefresh" Content="↻  Refresh" Style="{StaticResource BtnBlue}"/>
              </StackPanel>
            </Grid>
          </Border>
          <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="16,12,16,16">
              <!-- Database version -->
              <Border Background="#313244" CornerRadius="8" Padding="18" Margin="0,0,0,12">
                <StackPanel>
                  <TextBlock Text="DATABASE FULL VERSION" Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                  <TextBlock x:Name="txtSqlDbFull" Text="—" Foreground="#CBA6F7" FontSize="30" FontWeight="Bold" Margin="0,2,0,2"/>
                  <TextBlock x:Name="txtSqlDbSub" Foreground="#6C7086" FontSize="12" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
              <!-- Backups -->
              <Border Background="#313244" CornerRadius="8" Padding="18" Margin="0,0,0,12">
                <StackPanel>
                  <TextBlock Text="LAST BACKUPS" Foreground="#CBA6F7" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,10"/>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="130"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                      <RowDefinition Height="Auto"/>
                      <RowDefinition Height="Auto"/>
                      <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Ellipse x:Name="dotBkFull" Grid.Row="0" Grid.Column="0" Width="10" Height="10" Fill="#6C7086" Margin="0,0,10,8" VerticalAlignment="Center"/>
                    <TextBlock Grid.Row="0" Grid.Column="1" Text="Full" Foreground="#CDD6F4" Margin="0,0,0,8" VerticalAlignment="Center"/>
                    <TextBlock x:Name="txtBkFull" Grid.Row="0" Grid.Column="2" Text="—" Foreground="#CDD6F4" FontWeight="SemiBold" Margin="0,0,0,8" TextWrapping="Wrap"/>
                    <Ellipse x:Name="dotBkDiff" Grid.Row="1" Grid.Column="0" Width="10" Height="10" Fill="#6C7086" Margin="0,0,10,8" VerticalAlignment="Center"/>
                    <TextBlock Grid.Row="1" Grid.Column="1" Text="Differential" Foreground="#CDD6F4" Margin="0,0,0,8" VerticalAlignment="Center"/>
                    <TextBlock x:Name="txtBkDiff" Grid.Row="1" Grid.Column="2" Text="—" Foreground="#CDD6F4" Margin="0,0,0,8" TextWrapping="Wrap"/>
                    <Ellipse x:Name="dotBkLog" Grid.Row="2" Grid.Column="0" Width="10" Height="10" Fill="#6C7086" Margin="0,0,10,8" VerticalAlignment="Center"/>
                    <TextBlock Grid.Row="2" Grid.Column="1" Text="Transaction log" Foreground="#CDD6F4" Margin="0,0,0,8" VerticalAlignment="Center"/>
                    <TextBlock x:Name="txtBkLog" Grid.Row="2" Grid.Column="2" Text="—" Foreground="#CDD6F4" Margin="0,0,0,8" TextWrapping="Wrap"/>
                  </Grid>
                  <Border Height="1" Background="#45475A" Margin="0,4,0,10"/>
                  <TextBlock Text="LAST BACKUP SAVED TO" Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                  <TextBlock x:Name="txtBkPath" Text="—" Foreground="#CDD6F4" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,8"/>
                  <TextBlock Text="SQL DEFAULT BACKUP FOLDER" Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                  <TextBlock x:Name="txtBkDefault" Text="—" Foreground="#CDD6F4" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap" Margin="0,2,0,10"/>
                  <StackPanel Orientation="Horizontal">
                    <Button x:Name="btnBkOpenLast"    Content="Open Last Backup Folder" Style="{StaticResource BtnBlue}" Margin="0,0,6,0"/>
                    <Button x:Name="btnBkOpenDefault" Content="Open Default Folder"     Style="{StaticResource BtnBase}"/>
                  </StackPanel>
                </StackPanel>
              </Border>
              <!-- Files -->
              <Border Background="#313244" CornerRadius="8" Padding="18" Margin="0,0,0,12">
                <StackPanel>
                  <TextBlock Text="DATABASE FILES" Foreground="#CBA6F7" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,10"/>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition/>
                      <ColumnDefinition/>
                      <ColumnDefinition/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Margin="0,0,12,0">
                      <TextBlock Text="LOG FILE SIZE" Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                      <TextBlock x:Name="txtSqlLogSize" Text="—" Foreground="#CDD6F4" FontSize="22" FontWeight="Bold"/>
                      <TextBlock x:Name="txtSqlLogUsed" Foreground="#6C7086" FontSize="11" TextWrapping="Wrap"/>
                    </StackPanel>
                    <StackPanel Grid.Column="1" Margin="0,0,12,0">
                      <TextBlock Text="DATA FILE SIZE" Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                      <TextBlock x:Name="txtSqlDataSize" Text="—" Foreground="#CDD6F4" FontSize="22" FontWeight="Bold"/>
                      <TextBlock x:Name="txtSqlDataUsed" Foreground="#6C7086" FontSize="11" TextWrapping="Wrap"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2">
                      <TextBlock Text="RECOVERY MODEL" Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                      <TextBlock x:Name="txtSqlRecovery" Text="—" Foreground="#CDD6F4" FontSize="22" FontWeight="Bold"/>
                      <TextBlock x:Name="txtSqlLogWait" Foreground="#6C7086" FontSize="11" TextWrapping="Wrap"/>
                    </StackPanel>
                  </Grid>
                  <TextBlock x:Name="txtSqlFileWarn" Foreground="#F9E2AF" FontSize="12" TextWrapping="Wrap" Margin="0,10,0,0" Visibility="Collapsed"/>
                  <TextBlock x:Name="txtSqlFiles" Foreground="#6C7086" FontFamily="Consolas" FontSize="11" TextWrapping="Wrap" Margin="0,10,0,0"/>
                </StackPanel>
              </Border>
              <!-- SQL Server -->
              <Border Background="#313244" CornerRadius="8" Padding="18">
                <StackPanel>
                  <TextBlock Text="SQL SERVER" Foreground="#CBA6F7" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,10"/>
                  <TextBlock x:Name="txtSqlEdition" Text="—" Foreground="#CDD6F4" FontSize="14" FontWeight="SemiBold"/>
                  <TextBlock x:Name="txtSqlBuild"   Foreground="#6C7086" FontSize="12" Margin="0,2,0,0"/>
                  <TextBlock x:Name="txtSqlUptime"  Foreground="#6C7086" FontSize="12" Margin="0,2,0,0"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </Grid>
      </TabItem>
        <!-- Readers -->
        <TabItem Header="  Readers  " x:Name="tabReaders">
          <Grid Background="#1E1E2E">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="#181825" Padding="16,9">
              <Grid>
                <TextBlock x:Name="txtRdStatus" Foreground="#6C7086" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap" Margin="0,0,200,0"
                           Text="Read-only list of swiper and reader units from the EMBED database. Loads when you open this tab."/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                  <Button x:Name="btnRdCopy"    Content="Copy"       Style="{StaticResource BtnBase}" Margin="0,0,6,0" ToolTip="Copy the counts and the list shown below (tab-separated, pastes into Excel)"/>
                  <Button x:Name="btnRdRefresh" Content="↻  Refresh" Style="{StaticResource BtnBlue}"/>
                </StackPanel>
              </Grid>
            </Border>
            <!-- Counts -->
            <Grid Grid.Row="1" Margin="12,12,12,4">
              <Grid.ColumnDefinitions>
                <ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/>
              </Grid.ColumnDefinitions>
              <Border Grid.Column="0" Background="#313244" CornerRadius="8" Padding="14,10" Margin="0,0,8,0">
                <StackPanel>
                  <TextBlock Text="SWIPER UNITS" Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                  <TextBlock x:Name="txtRdSwipers" Text="—" Foreground="#CBA6F7" FontSize="28" FontWeight="Bold"/>
                  <TextBlock x:Name="txtRdSwipersSub" Foreground="#6C7086" FontSize="10"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="1" Background="#313244" CornerRadius="8" Padding="14,10" Margin="0,0,8,0">
                <StackPanel>
                  <TextBlock Text="READER UNITS" Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                  <TextBlock x:Name="txtRdReaders" Text="—" Foreground="#89B4FA" FontSize="28" FontWeight="Bold"/>
                  <TextBlock x:Name="txtRdReadersSub" Foreground="#6C7086" FontSize="10"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="2" Background="#313244" CornerRadius="8" Padding="14,10" Margin="0,0,8,0">
                <StackPanel>
                  <TextBlock Text="STS READERS" Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                  <TextBlock x:Name="txtRdSts" Text="—" Foreground="#CDD6F4" FontSize="28" FontWeight="Bold"/>
                  <TextBlock Text="readers" Foreground="#6C7086" FontSize="10"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="3" Background="#313244" CornerRadius="8" Padding="14,10" Margin="0,0,8,0">
                <StackPanel>
                  <TextBlock Text="STP READERS" Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                  <TextBlock x:Name="txtRdStp" Text="—" Foreground="#CDD6F4" FontSize="28" FontWeight="Bold"/>
                  <TextBlock Text="readers" Foreground="#6C7086" FontSize="10"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="4" Background="#313244" CornerRadius="8" Padding="14,10">
                <StackPanel>
                  <TextBlock Text="PAUSED" Foreground="#6C7086" FontSize="10" FontWeight="SemiBold"/>
                  <TextBlock x:Name="txtRdPaused" Text="—" Foreground="#F9E2AF" FontSize="28" FontWeight="Bold"/>
                  <TextBlock Text="swiper units" Foreground="#6C7086" FontSize="10"/>
                </StackPanel>
              </Border>
            </Grid>
            <!-- Search -->
            <Border Grid.Row="2" Background="#181825" Padding="16,8" Margin="0,8,0,0">
              <WrapPanel VerticalAlignment="Center">
                <TextBlock Text="Search:" Foreground="#6C7086" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <TextBox x:Name="txtRdSearch" Width="240" Margin="0,0,16,0" ToolTip="Game name, description, Game Id, Swiper Id, Reader Id or IP"/>
                <TextBlock Text="Type:" Foreground="#6C7086" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <Button x:Name="btnRdAll" Content="All" Style="{StaticResource BtnPurple}" Margin="0,0,4,0"/>
                <Button x:Name="btnRdSts" Content="STS" Style="{StaticResource BtnBase}"   Margin="0,0,4,0"/>
                <Button x:Name="btnRdStp" Content="STP" Style="{StaticResource BtnBase}"   Margin="0,0,16,0"/>
                <CheckBox x:Name="chkRdRetired" Content="Show retired" Foreground="#CDD6F4" VerticalAlignment="Center" Margin="0,0,16,0"/>
                <TextBlock x:Name="txtRdCount" Foreground="#6C7086" FontSize="12" VerticalAlignment="Center"/>
              </WrapPanel>
            </Border>
            <DataGrid x:Name="dgReaders" Grid.Row="3" Margin="12,8,12,8" CanUserSortColumns="True">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Type"         Binding="{Binding Type}"        Width="60"/>
                <DataGridTextColumn Header="Game name"    Binding="{Binding GameName}"    Width="*"/>
                <DataGridTextColumn Header="Description"  Binding="{Binding Description}" Width="*"/>
                <DataGridTextColumn Header="Game Id"      Binding="{Binding GameId}"      Width="150"/>
                <DataGridTextColumn Header="Swiper"       Binding="{Binding SwiperId}"    Width="65"/>
                <DataGridTextColumn Header="Reader Id"    Binding="{Binding ReaderId}"    Width="110"/>
                <DataGridTextColumn Header="IP address"   Binding="{Binding Ip}"          Width="110"/>
                <DataGridTextColumn Header="Poll grp"     Binding="{Binding PollGroup}"   Width="65"/>
                <DataGridTextColumn Header="Paused"       Binding="{Binding Paused}"      Width="60"/>
                <DataGridTextColumn Header="Status"       Binding="{Binding Status}"      Width="60"/>
                <DataGridTextColumn Header="Last comms"   Binding="{Binding LastComms}"   Width="125"/>
                <DataGridTextColumn Header="Media ver."   Binding="{Binding MediaVer}"    Width="90"/>
              </DataGrid.Columns>
            </DataGrid>
          </Grid>
        </TabItem>
      <!-- Devices -->
      <TabItem Header="  Devices  ">
        <Grid Background="#1E1E2E">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" Background="#181825" Padding="16,9">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="Device name:" Foreground="#6C7086" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBox x:Name="txtDevName" Width="200" Margin="0,0,8,0" ToolTip="Computer name, e.g. FRONTDESK-PC"/>
                <Button x:Name="btnDevAdd" Content="Add Device" Style="{StaticResource BtnPurple}"/>
              </StackPanel>
              <TextBlock Grid.Column="1" x:Name="txtDevStatus" Foreground="#6C7086" FontSize="12"
                         VerticalAlignment="Center" Margin="14,0,0,0"/>
              <StackPanel Grid.Column="2" Orientation="Horizontal">
                <TextBlock Text="Check every" Foreground="#6C7086" FontSize="12" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <TextBox x:Name="txtDevEvery" Width="50" Margin="0,0,4,0" VerticalAlignment="Center"
                         ToolTip="Seconds between automatic device checks (30 to 3600). Press Enter to apply."/>
                <TextBlock Text="sec" Foreground="#6C7086" FontSize="12" VerticalAlignment="Center" Margin="0,0,14,0"/>
                <Button x:Name="btnDevDiscover" Content="Discover..." Style="{StaticResource BtnPurple}" Margin="0,0,6,0"/>
                <Button x:Name="btnDevCheck"    Content="Check Now"   Style="{StaticResource BtnBlue}"/>
              </StackPanel>
            </Grid>
          </Border>
          <DataGrid x:Name="dgDevices" Grid.Row="1" Margin="12,8,12,8">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Device"        Binding="{Binding Name}"        Width="150"/>
              <DataGridTextColumn Header="Status"        Binding="{Binding Status}"      Width="130">
                <DataGridTextColumn.ElementStyle>
                  <Style TargetType="TextBlock">
                    <Setter Property="Foreground" Value="#CDD6F4"/>
                    <Style.Triggers>
                    <DataTrigger Binding="{Binding Status}" Value="Online"><Setter Property="Foreground" Value="#A6E3A1"/></DataTrigger>
                    <DataTrigger Binding="{Binding Status}" Value="Online (no RDP)"><Setter Property="Foreground" Value="#F9E2AF"/></DataTrigger>
                    <DataTrigger Binding="{Binding Status}" Value="Online (no DNS)"><Setter Property="Foreground" Value="#F9E2AF"/></DataTrigger>
                    <DataTrigger Binding="{Binding Status}" Value="Offline"><Setter Property="Foreground" Value="#F38BA8"/></DataTrigger>
                    <DataTrigger Binding="{Binding Status}" Value="Unresolved"><Setter Property="Foreground" Value="#FAB387"/></DataTrigger>
                    </Style.Triggers>
                  </Style>
                </DataGridTextColumn.ElementStyle>
              </DataGridTextColumn>
              <DataGridTextColumn Header="Current IP"    Binding="{Binding CurrentIP}"   Width="115"/>
              <DataGridTextColumn Header="Last known IP" Binding="{Binding LastKnownIP}" Width="115"/>
              <DataGridTextColumn Header="Last seen"     Binding="{Binding LastSeen}"    Width="150"/>
              <DataGridTextColumn Header="Details"       Binding="{Binding Detail}"      Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
          <Border Grid.Row="2" Background="#181825" Padding="16,9">
            <StackPanel Orientation="Horizontal">
              <Button x:Name="btnDevConnect"  Content="Connect (RDP)" Style="{StaticResource BtnGreen}"  Margin="0,0,6,0"/>
              <Button x:Name="btnDevPing"     Content="Ping"          Style="{StaticResource BtnBlue}"   Margin="0,0,6,0"/>
              <Button x:Name="btnDevServices" Content="Services..."   Style="{StaticResource BtnPurple}" Margin="0,0,6,0"/>
              <Button x:Name="btnDevSoftware" Content="Software..."   Style="{StaticResource BtnPurple}" Margin="0,0,6,0"/>
              <Button x:Name="btnDevRemove"   Content="Remove"        Style="{StaticResource BtnRed}"/>
              <TextBlock Text="Select a device in the list first" Foreground="#6C7086" FontSize="12"
                         VerticalAlignment="Center" Margin="14,0,0,0"/>
            </StackPanel>
          </Border>
          <!-- Remote services panel (covers the Devices list while open) -->
          <Grid x:Name="pnlRemote" Grid.RowSpan="3" Background="#1E1E2E" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="#181825" Padding="16,9">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="Computer:" Foreground="#6C7086" VerticalAlignment="Center" Margin="0,0,8,0"/>
                  <TextBox x:Name="txtRemHost" Width="200" Margin="0,0,8,0" ToolTip="Computer name or IP"/>
                  <Button x:Name="btnRemLoad"  Content="Load Services" Style="{StaticResource BtnBlue}" Margin="0,0,6,0"/>
                  <Button x:Name="btnRemClose" Content="Close"         Style="{StaticResource BtnBase}"/>
                </StackPanel>
                <TextBlock x:Name="txtRemStatus" Foreground="#6C7086" FontSize="12" TextWrapping="Wrap" Margin="0,8,0,0"
                           Text="Uses your Windows login. You must be an administrator on the remote PC."/>
              </StackPanel>
            </Border>
            <DataGrid x:Name="dgRemote" Grid.Row="1" Margin="12,8,12,8">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Service" Binding="{Binding Display}"   Width="*"/>
                <DataGridTextColumn Header="Name"    Binding="{Binding Name}"      Width="160"/>
                <DataGridTextColumn Header="Status"  Binding="{Binding Status}"    Width="110">
                  <DataGridTextColumn.ElementStyle>
                    <Style TargetType="TextBlock">
                      <Setter Property="Foreground" Value="#CDD6F4"/>
                      <Style.Triggers>
                        <DataTrigger Binding="{Binding Status}" Value="Running"><Setter Property="Foreground" Value="#A6E3A1"/></DataTrigger>
                        <DataTrigger Binding="{Binding Status}" Value="Stopped"><Setter Property="Foreground" Value="#F38BA8"/></DataTrigger>
                        <DataTrigger Binding="{Binding Status}" Value="Error"><Setter Property="Foreground" Value="#FAB387"/></DataTrigger>
                      </Style.Triggers>
                    </Style>
                  </DataGridTextColumn.ElementStyle>
                </DataGridTextColumn>
                <DataGridTextColumn Header="Startup" Binding="{Binding StartType}" Width="100"/>
              </DataGrid.Columns>
            </DataGrid>
            <Border Grid.Row="2" Background="#181825" Padding="16,9">
              <StackPanel Orientation="Horizontal">
                <Button x:Name="btnRemStart"   Content="▶  Start"   Style="{StaticResource BtnGreen}"  Margin="0,0,6,0"/>
                <Button x:Name="btnRemStop"    Content="■  Stop"    Style="{StaticResource BtnRed}"    Margin="0,0,6,0"/>
                <Button x:Name="btnRemRestart" Content="↺  Restart" Style="{StaticResource BtnYellow}" Margin="0,0,6,0"/>
                <Button x:Name="btnRemStack"   Content="↺  Restart EMBED Stack" Style="{StaticResource BtnPurple}"/>
                <TextBlock Text="Start / Stop / Restart act on the selected row" Foreground="#6C7086" FontSize="12"
                           VerticalAlignment="Center" Margin="14,0,0,0"/>
              </StackPanel>
            </Border>
          </Grid>
          <!-- Discover panel (covers the Devices list while open) -->
          <Grid x:Name="pnlDiscover" Grid.RowSpan="3" Background="#1E1E2E" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="#181825" Padding="16,9">
              <StackPanel Orientation="Horizontal">
                <Button x:Name="btnDscScan" Content="Scan Network" Style="{StaticResource BtnBlue}"/>
                <TextBlock x:Name="txtDscStatus" Foreground="#6C7086" FontSize="12" VerticalAlignment="Center"
                           Margin="14,0,0,0" Text="Scans this server's network for PCs. Nothing is added until you tick it."/>
              </StackPanel>
            </Border>
            <Border Grid.Row="1" Background="#181825" Padding="16,0,16,9">
              <WrapPanel VerticalAlignment="Center">
                <CheckBox x:Name="chkDscRdp"     Content="Only PCs with Remote Desktop open" IsChecked="True"
                          Foreground="#CDD6F4" VerticalAlignment="Center" Margin="0,0,16,0"/>
                <CheckBox x:Name="chkDscReaders" Content="Hide GURU card readers" IsChecked="True"
                          Foreground="#CDD6F4" VerticalAlignment="Center" Margin="0,0,16,0"/>
                <CheckBox x:Name="chkDscAuto"    Content="Add new PCs automatically after each scan" IsChecked="True"
                          Foreground="#CDD6F4" VerticalAlignment="Center" Margin="0,0,16,0"/>
                <TextBlock Text="Search:" Foreground="#6C7086" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <TextBox x:Name="txtDscSearch" Width="160" Margin="0,0,16,0"/>
                <TextBlock x:Name="txtDscCount" Foreground="#6C7086" FontSize="12" VerticalAlignment="Center"/>
              </WrapPanel>
            </Border>
            <DataGrid x:Name="dgDisc" Grid.Row="2" Margin="12,8,12,8" IsReadOnly="False">
              <DataGrid.Columns>
                <DataGridTemplateColumn Header="Add" Width="55">
                  <DataGridTemplateColumn.CellTemplate>
                    <DataTemplate>
                      <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </DataTemplate>
                  </DataGridTemplateColumn.CellTemplate>
                </DataGridTemplateColumn>
                <DataGridTextColumn Header="Name"           Binding="{Binding Name, Mode=OneWay}" Width="210" IsReadOnly="True"/>
                <DataGridTextColumn Header="IP address"     Binding="{Binding Ip, Mode=OneWay}"   Width="120" IsReadOnly="True"/>
                <DataGridTextColumn Header="Remote Desktop" Binding="{Binding Rdp, Mode=OneWay}"  Width="125" IsReadOnly="True"/>
                <DataGridTextColumn Header="Note"           Binding="{Binding Note, Mode=OneWay}" Width="*"   IsReadOnly="True"/>
              </DataGrid.Columns>
            </DataGrid>
            <Border Grid.Row="3" Background="#181825" Padding="16,9">
              <StackPanel Orientation="Horizontal">
                <Button x:Name="btnDscAdd"    Content="Add Selected"    Style="{StaticResource BtnGreen}"  Margin="0,0,6,0"/>
                <Button x:Name="btnDscIgnore" Content="Ignore Selected" Style="{StaticResource BtnYellow}" Margin="0,0,6,0"/>
                <Button x:Name="btnDscClose"  Content="Close"           Style="{StaticResource BtnBase}"/>
                <TextBlock Text="Ignored devices stay hidden in future scans" Foreground="#6C7086" FontSize="12"
                           VerticalAlignment="Center" Margin="14,0,0,0"/>
              </StackPanel>
            </Border>
          </Grid>
        </Grid>
      </TabItem>
      <!-- Software -->
      <TabItem Header="  Software  " x:Name="tabSoftware">
        <Grid Background="#1E1E2E">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" Background="#181825" Padding="16,9">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Station:" Foreground="#6C7086" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <TextBox x:Name="txtSwStation" Width="220" Margin="0,0,14,0" ToolTip="Computer name or IP (or pick a device on the Devices tab and click Software...)"/>
              <TextBlock x:Name="txtSwStatus" Foreground="#6C7086" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap"
                         Text="Pick a package, enter the station, then Copy or Copy + Install."/>
            </StackPanel>
          </Border>
          <DataGrid x:Name="dgPackages" Grid.Row="1" Margin="12,8,12,8" IsReadOnly="False" CanUserAddRows="False" CanUserDeleteRows="False">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Package"           Binding="{Binding Name, Mode=OneWay}"      Width="170" IsReadOnly="True"/>
              <DataGridTextColumn Header="Installer (server)" Binding="{Binding Installer, Mode=OneWay}" Width="2*" IsReadOnly="True"/>
              <DataGridTextColumn Header="Copies"            Binding="{Binding Copy, Mode=OneWay}"      Width="110" IsReadOnly="True"/>
              <DataGridTextColumn Header="Install arguments (double-click to edit)" Binding="{Binding Args, Mode=TwoWay, UpdateSourceTrigger=LostFocus}" Width="*"/>
              <DataGridTextColumn Header="Last result"       Binding="{Binding Result, Mode=OneWay}"    Width="*" IsReadOnly="True"/>
            </DataGrid.Columns>
          </DataGrid>
          <Border Grid.Row="2" Background="#181825" Padding="16,9">
            <Grid>
              <StackPanel Orientation="Horizontal">
                <Button x:Name="btnSwCopy"    Content="⬇  Copy to Station"  Style="{StaticResource BtnBlue}"  Margin="0,0,6,0" ToolTip="Places the installer on the station without running it"/>
                <Button x:Name="btnSwInstall" Content="⬇  Copy + Install"   Style="{StaticResource BtnGreen}" Margin="0,0,6,0" ToolTip="Places the installer on the station and runs it silently"/>
                <Button x:Name="btnSwOpen"    Content="Open on Station"     Style="{StaticResource BtnBase}"/>
              </StackPanel>
              <Button x:Name="btnSwRemove" Content="Remove Package" Style="{StaticResource BtnRed}" HorizontalAlignment="Right"/>
            </Grid>
          </Border>
          <TextBox x:Name="txtSwLog" Grid.Row="3" Height="130" Margin="12,8,12,8" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
          <Border Grid.Row="4" Background="#313244" CornerRadius="8" Padding="14,10" Margin="12,0,12,10">
            <StackPanel>
              <TextBlock Text="ADD PACKAGE" Foreground="#CBA6F7" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,8"/>
              <WrapPanel>
                <TextBlock Text="Name" Foreground="#6C7086" VerticalAlignment="Center" Margin="0,0,6,6"/>
                <TextBox x:Name="txtPkgName" Width="150" Margin="0,0,12,6" ToolTip="e.g. Kiosk"/>
                <TextBlock Text="Installer" Foreground="#6C7086" VerticalAlignment="Center" Margin="0,0,6,6"/>
                <TextBox x:Name="txtPkgPath" Width="300" Margin="0,0,4,6" ToolTip="Full path of the .exe or .msi on this server"/>
                <Button x:Name="btnPkgBrowse" Content="..." Style="{StaticResource BtnBase}" Margin="0,0,12,6"/>
                <TextBlock Text="Arguments" Foreground="#6C7086" VerticalAlignment="Center" Margin="0,0,6,6"/>
                <TextBox x:Name="txtPkgArgs" Width="160" Margin="0,0,12,6" ToolTip="Silent install switches, e.g. /S, /quiet, /VERYSILENT. MSI defaults to /qn /norestart."/>
                <CheckBox x:Name="chkPkgFolder" Content="Copy whole folder" IsChecked="True" Foreground="#CDD6F4" VerticalAlignment="Center" Margin="0,0,12,6"
                          ToolTip="On = copy every file next to the installer (needed by most installers)"/>
                <Button x:Name="btnPkgAdd"  Content="Add"            Style="{StaticResource BtnPurple}" Margin="0,0,6,6"/>
                <Button x:Name="btnPkgScan" Content="Scan Folder..." Style="{StaticResource BtnBlue}"   Margin="0,0,0,6" ToolTip="Add every .exe / .msi found in a server folder"/>
              </WrapPanel>
              <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                <TextBlock Text="Station folder" Foreground="#6C7086" VerticalAlignment="Center" Margin="0,0,6,0"/>
                <TextBox x:Name="txtSwRoot" Width="260" Margin="0,0,6,0" ToolTip="Where installers are placed on the station (each package gets its own subfolder)"/>
                <Button x:Name="btnSwRootSave" Content="Save" Style="{StaticResource BtnBase}"/>
              </StackPanel>
            </StackPanel>
          </Border>
        </Grid>
      </TabItem>
      <!-- Settings -->
      <TabItem Header="  Settings  ">
        <ScrollViewer Background="#1E1E2E" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="20,16,20,20">
            <Border Background="#313244" CornerRadius="8" Padding="18" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="TIMERS" Foreground="#CBA6F7" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,4"/>
                <TextBlock Text="The device check interval is set on the Devices tab."
                           Foreground="#6C7086" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,14"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="210"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="Service refresh (seconds)" Foreground="#CDD6F4" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <StackPanel Grid.Row="0" Grid.Column="1" Orientation="Horizontal" Margin="0,0,0,10">
                    <TextBox x:Name="txtRefreshEvery" Width="80" ToolTip="10 to 5400 seconds (90 minutes)"/>
                    <TextBlock x:Name="txtRefreshHint" Foreground="#6C7086" FontSize="11" VerticalAlignment="Center" Margin="10,0,0,0"/>
                  </StackPanel>
                  <TextBlock Grid.Row="1" Text="Database version + SQL tab" Foreground="#CDD6F4" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock Grid.Row="1" Grid.Column="1" Text="Every 24 hours, at startup, and when you click Refresh" Foreground="#6C7086" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock Grid.Row="2" Text="History logs" Foreground="#CDD6F4" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBlock Grid.Row="2" Grid.Column="1" Text="Kept for 3 days" Foreground="#6C7086" VerticalAlignment="Center" Margin="0,0,0,10"/>
                </Grid>
                <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                  <Button x:Name="btnTimersSave" Content="Save Timers" Style="{StaticResource BtnPurple}" Margin="0,0,8,0"/>
                  <TextBlock x:Name="txtTimersStatus" Foreground="#6C7086" FontSize="12" VerticalAlignment="Center" Margin="6,0,0,0"/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Background="#313244" CornerRadius="8" Padding="18">
              <StackPanel>
                <TextBlock Text="EMAIL ALERTS (SMTP)" Foreground="#CBA6F7" FontSize="11"
                           FontWeight="SemiBold" Margin="0,0,0,4"/>
                <TextBlock Text="Sends an email to the support address when a service goes offline repeatedly within a time window."
                           Foreground="#6C7086" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,14"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="210"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Grid.Column="0" Text="Enable email alerts" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <CheckBox x:Name="chkSmtpEnabled" Grid.Row="0" Grid.Column="1" Style="{StaticResource SwitchToggle}" HorizontalAlignment="Left" Margin="0,0,0,10"/>
                  <TextBlock Grid.Row="1" Grid.Column="0" Text="SMTP server" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBox x:Name="txtSmtpServer" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Left" Width="320" Margin="0,0,0,10"/>
                  <TextBlock Grid.Row="2" Grid.Column="0" Text="Port" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBox x:Name="txtSmtpPort" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Left" Width="80" Margin="0,0,0,10"/>
                  <TextBlock Grid.Row="3" Grid.Column="0" Text="Use SSL / TLS (STARTTLS)" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <CheckBox x:Name="chkSmtpSsl" Grid.Row="3" Grid.Column="1" Style="{StaticResource SwitchToggle}" HorizontalAlignment="Left" Margin="0,0,0,10"/>
                  <TextBlock Grid.Row="4" Grid.Column="0" Text="Username (optional)" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBox x:Name="txtSmtpUser" Grid.Row="4" Grid.Column="1" HorizontalAlignment="Left" Width="320" Margin="0,0,0,10"/>
                  <TextBlock Grid.Row="5" Grid.Column="0" Text="Password (optional)" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <StackPanel Grid.Row="5" Grid.Column="1" Orientation="Horizontal" Margin="0,0,0,10"><PasswordBox x:Name="pwdSmtp" Width="320"/><TextBlock x:Name="txtPwdHint" Foreground="#6C7086" FontSize="11" VerticalAlignment="Center" Margin="10,0,0,0"/></StackPanel>
                  <TextBlock Grid.Row="6" Grid.Column="0" Text="From address" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBox x:Name="txtSmtpFrom" Grid.Row="6" Grid.Column="1" HorizontalAlignment="Left" Width="320" Margin="0,0,0,10"/>
                  <TextBlock Grid.Row="7" Grid.Column="0" Text="Send alerts to" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBox x:Name="txtSmtpTo" Grid.Row="7" Grid.Column="1" HorizontalAlignment="Left" Width="320" Margin="0,0,0,10" ToolTip="Support email address. Separate several addresses with commas."/>
                  <TextBlock Grid.Row="8" Grid.Column="0" Text="Alert after offline events" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBox x:Name="txtSmtpThreshold" Grid.Row="8" Grid.Column="1" HorizontalAlignment="Left" Width="80" Margin="0,0,0,10" ToolTip="Number of times a service goes offline before an email is sent"/>
                  <TextBlock Grid.Row="9" Grid.Column="0" Text="...within (minutes)" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBox x:Name="txtSmtpWindow" Grid.Row="9" Grid.Column="1" HorizontalAlignment="Left" Width="80" Margin="0,0,0,10"/>
                  <TextBlock Grid.Row="10" Grid.Column="0" Text="Resend cooldown (minutes)" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBox x:Name="txtSmtpCooldown" Grid.Row="10" Grid.Column="1" HorizontalAlignment="Left" Width="80" Margin="0,0,0,10" ToolTip="Minimum time before another email is sent for the same service"/>
                </Grid>
                <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                  <Button x:Name="btnSmtpSave" Content="Save Settings"    Style="{StaticResource BtnPurple}" Margin="0,0,8,0"/>
                  <Button x:Name="btnSmtpTest" Content="Send Test Email"  Style="{StaticResource BtnBlue}"/>
                  <TextBlock x:Name="txtSmtpStatus" Foreground="#6C7086" FontSize="12"
                             VerticalAlignment="Center" Margin="14,0,0,0"/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Background="#313244" CornerRadius="8" Padding="18" Margin="0,14,0,0">
              <StackPanel>
                <TextBlock Text="SUPPORT SNAPSHOTS" Foreground="#CBA6F7" FontSize="11" FontWeight="SemiBold" Margin="0,0,0,4"/>
                <TextBlock Text="Old snapshots are deleted automatically whenever a new one is made and when the dashboard starts. Set Keep to 1 to only keep the latest one."
                           Foreground="#6C7086" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,14"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="210"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Text="Keep last (snapshots)" Foreground="#CDD6F4" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBox x:Name="txtSnapKeep" Grid.Row="0" Grid.Column="1" HorizontalAlignment="Left" Width="80" Margin="0,0,0,10"/>
                  <TextBlock Grid.Row="1" Text="Delete after (days, 0 = never)" Foreground="#CDD6F4" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBox x:Name="txtSnapDays" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Left" Width="80" Margin="0,0,0,10"/>
                  <TextBlock Grid.Row="2" Text="SQL Server" Foreground="#CDD6F4" VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBox x:Name="txtSqlServer" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Left" Width="320" Margin="0,0,0,10"
                           ToolTip="localhost, SERVER\INSTANCE or SERVER,PORT. Used by snapshots and Discover."/>
                </Grid>
                <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                  <Button x:Name="btnSnapSave" Content="Save Snapshot Settings" Style="{StaticResource BtnPurple}" Margin="0,0,8,0"/>
                  <Button x:Name="btnSnapOpen" Content="Open Snapshot Folder"   Style="{StaticResource BtnBlue}"/>
                  <TextBlock x:Name="txtSnapStatus" Foreground="#6C7086" FontSize="12" VerticalAlignment="Center" Margin="14,0,0,0"/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Background="#313244" CornerRadius="8" Padding="18" Margin="0,14,0,0">
              <StackPanel>
                <TextBlock Text="APP UPDATES (GITHUB)" Foreground="#CBA6F7" FontSize="11"
                           FontWeight="SemiBold" Margin="0,0,0,4"/>
                <TextBlock x:Name="txtUpdVersion" Foreground="#CDD6F4" FontSize="13" Margin="0,0,0,4"/>
                <TextBlock Text="Checks a GitHub repository for a newer version of this dashboard. Each update is verified and the current version is backed up first."
                           Foreground="#6C7086" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,14"/>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="210"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Grid.Column="0" Text="Repository (owner/name)" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBox x:Name="txtUpdRepo" Grid.Row="0" Grid.Column="1" HorizontalAlignment="Left" Width="320" Margin="0,0,0,10" ToolTip="Example: mycompany/embed-dashboard"/>
                  <TextBlock Grid.Row="1" Grid.Column="0" Text="Branch" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <TextBox x:Name="txtUpdBranch" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Left" Width="160" Margin="0,0,0,10"/>
                  <TextBlock Grid.Row="2" Grid.Column="0" Text="Access token (private repos only)" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <StackPanel Grid.Row="2" Grid.Column="1" Orientation="Horizontal" Margin="0,0,0,10"><PasswordBox x:Name="pwdUpdToken" Width="320"/><TextBlock x:Name="txtUpdTokenHint" Foreground="#6C7086" FontSize="11" VerticalAlignment="Center" Margin="10,0,0,0"/></StackPanel>
                  <TextBlock Grid.Row="3" Grid.Column="0" Text="Check for updates automatically" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <CheckBox x:Name="chkUpdAuto" Grid.Row="3" Grid.Column="1" Style="{StaticResource SwitchToggle}" HorizontalAlignment="Left" Margin="0,0,0,10" ToolTip="Checks at startup and every 6 hours"/>
                  <TextBlock Grid.Row="4" Grid.Column="0" Text="Install updates automatically" Foreground="#CDD6F4"
                             VerticalAlignment="Center" Margin="0,0,0,10"/>
                  <CheckBox x:Name="chkUpdInstall" Grid.Row="4" Grid.Column="1" Style="{StaticResource SwitchToggle}" HorizontalAlignment="Left" Margin="0,0,0,10" ToolTip="When on, a new version is installed and the dashboard restarts by itself"/>
                </Grid>
                <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                  <Button x:Name="btnUpdSave"    Content="Save Update Settings" Style="{StaticResource BtnPurple}" Margin="0,0,8,0"/>
                  <Button x:Name="btnUpdCheck"   Content="Check for Updates"    Style="{StaticResource BtnBlue}"   Margin="0,0,8,0"/>
                  <Button x:Name="btnUpdInstall" Content="Install Update"       Style="{StaticResource BtnGreen}"  Visibility="Collapsed"/>
                </StackPanel>
                <TextBlock x:Name="txtUpdStatus" Foreground="#6C7086" FontSize="12" TextWrapping="Wrap" Margin="0,10,0,0"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </TabItem>
    </TabControl>
    <!-- STATUS BAR -->
    <Border Grid.Row="2" Background="#11111B" Padding="14,0">
      <Grid>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Ellipse x:Name="statusDot"
                   Width="8"
                   Height="8"
                   Fill="#CBA6F7"
                   Margin="0,0,6,0"/>
          <TextBlock x:Name="statusBar"
                     Foreground="#6C7086"
                     FontSize="11"
                     VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock x:Name="statusBarRight"
                   Foreground="#6C7086"
                   FontSize="11"
                   VerticalAlignment="Center"
                   HorizontalAlignment="Right"/>
      </Grid>
    </Border>
  </Grid>
</Window>
"@
# ------------------------------------------------------------
# LOAD XAML + GET CONTROLS
# ------------------------------------------------------------
$reader = New-Object System.Xml.XmlNodeReader $XAML
try   { $window = [Windows.Markup.XamlReader]::Load($reader) }
catch { Write-Error "XAML load failed: $_"; exit 1 }
function Get-Ctrl($n) { $window.FindName($n) }
$txtCountdown     = Get-Ctrl 'txtCountdown'
$adminBadge       = Get-Ctrl 'adminBadge'
$nonAdminBadge    = Get-Ctrl 'nonAdminBadge'
$btnRefresh       = Get-Ctrl 'btnRefresh'
$btnClearHistory  = Get-Ctrl 'btnClearHistory'
$btnFilterAll     = Get-Ctrl 'btnFilterAll'
$btnFilterCore    = Get-Ctrl 'btnFilterCore'
$btnFilterApi     = Get-Ctrl 'btnFilterApi'
$btnFilterSQL     = Get-Ctrl 'btnFilterSQL'
$btnFilterRemote  = Get-Ctrl 'btnFilterRemote'
$btnStartAll      = Get-Ctrl 'btnStartAll'
$btnStopAll       = Get-Ctrl 'btnStopAll'
$btnRestartAll    = Get-Ctrl 'btnRestartAll'
$ServicePanel     = Get-Ctrl 'ServicePanel'
$HistoryGrid      = Get-Ctrl 'HistoryGrid'
$statRunning      = Get-Ctrl 'statRunning'
$statStopped      = Get-Ctrl 'statStopped'
$statOther        = Get-Ctrl 'statOther'
$statEvents       = Get-Ctrl 'statEvents'
$EventsGrid       = Get-Ctrl 'EventsGrid'
$btnRefreshEvents = Get-Ctrl 'btnRefreshEvents'
$btnClearEvents   = Get-Ctrl 'btnClearEvents'
$statLastScan     = Get-Ctrl 'statLastScan'
$GroupHealthPanel = Get-Ctrl 'GroupHealthPanel'
$statusBar        = Get-Ctrl 'statusBar'
$statusBarRight   = Get-Ctrl 'statusBarRight'
$statusDot        = Get-Ctrl 'statusDot'
$chkSmtpEnabled   = Get-Ctrl 'chkSmtpEnabled'
$txtSmtpServer    = Get-Ctrl 'txtSmtpServer'
$txtSmtpPort      = Get-Ctrl 'txtSmtpPort'
$chkSmtpSsl       = Get-Ctrl 'chkSmtpSsl'
$txtSmtpUser      = Get-Ctrl 'txtSmtpUser'
$pwdSmtp          = Get-Ctrl 'pwdSmtp'
$txtPwdHint       = Get-Ctrl 'txtPwdHint'
$txtSmtpFrom      = Get-Ctrl 'txtSmtpFrom'
$txtSmtpTo        = Get-Ctrl 'txtSmtpTo'
$txtSmtpThreshold = Get-Ctrl 'txtSmtpThreshold'
$txtSmtpWindow    = Get-Ctrl 'txtSmtpWindow'
$txtSmtpCooldown  = Get-Ctrl 'txtSmtpCooldown'
$btnSmtpSave      = Get-Ctrl 'btnSmtpSave'
$btnSmtpTest      = Get-Ctrl 'btnSmtpTest'
$txtSmtpStatus    = Get-Ctrl 'txtSmtpStatus'
$txtDevName       = Get-Ctrl 'txtDevName'
$btnDevAdd        = Get-Ctrl 'btnDevAdd'
$btnDevCheck      = Get-Ctrl 'btnDevCheck'
$txtDevStatus     = Get-Ctrl 'txtDevStatus'
$dgDevices        = Get-Ctrl 'dgDevices'
$btnDevConnect    = Get-Ctrl 'btnDevConnect'
$btnDevPing       = Get-Ctrl 'btnDevPing'
$btnDevRemove     = Get-Ctrl 'btnDevRemove'
$btnDevDiscover   = Get-Ctrl 'btnDevDiscover'
$pnlDiscover      = Get-Ctrl 'pnlDiscover'
$btnDscScan       = Get-Ctrl 'btnDscScan'
$txtDscStatus     = Get-Ctrl 'txtDscStatus'
$chkDscRdp        = Get-Ctrl 'chkDscRdp'
$chkDscReaders    = Get-Ctrl 'chkDscReaders'
$txtDscSearch     = Get-Ctrl 'txtDscSearch'
$txtDscCount      = Get-Ctrl 'txtDscCount'
$dgDisc           = Get-Ctrl 'dgDisc'
$btnDscAdd        = Get-Ctrl 'btnDscAdd'
$btnDscIgnore     = Get-Ctrl 'btnDscIgnore'
$btnDscClose      = Get-Ctrl 'btnDscClose'
$chkDscAuto       = Get-Ctrl 'chkDscAuto'
$txtUpdVersion    = Get-Ctrl 'txtUpdVersion'
$txtUpdRepo       = Get-Ctrl 'txtUpdRepo'
$txtUpdBranch     = Get-Ctrl 'txtUpdBranch'
$pwdUpdToken      = Get-Ctrl 'pwdUpdToken'
$txtUpdTokenHint  = Get-Ctrl 'txtUpdTokenHint'
$chkUpdAuto       = Get-Ctrl 'chkUpdAuto'
$chkUpdInstall    = Get-Ctrl 'chkUpdInstall'
$btnUpdSave       = Get-Ctrl 'btnUpdSave'
$btnUpdCheck      = Get-Ctrl 'btnUpdCheck'
$btnUpdInstall    = Get-Ctrl 'btnUpdInstall'
$txtUpdStatus     = Get-Ctrl 'txtUpdStatus'
$btnSnapshot      = Get-Ctrl 'btnSnapshot'
$btnDevServices   = Get-Ctrl 'btnDevServices'
$pnlRemote        = Get-Ctrl 'pnlRemote'
$txtRemHost       = Get-Ctrl 'txtRemHost'
$btnRemLoad       = Get-Ctrl 'btnRemLoad'
$btnRemClose      = Get-Ctrl 'btnRemClose'
$txtRemStatus     = Get-Ctrl 'txtRemStatus'
$dgRemote         = Get-Ctrl 'dgRemote'
$btnRemStart      = Get-Ctrl 'btnRemStart'
$btnRemStop       = Get-Ctrl 'btnRemStop'
$btnRemRestart    = Get-Ctrl 'btnRemRestart'
$btnRemStack      = Get-Ctrl 'btnRemStack'
$txtSnapKeep      = Get-Ctrl 'txtSnapKeep'
$txtSnapDays      = Get-Ctrl 'txtSnapDays'
$txtSqlServer     = Get-Ctrl 'txtSqlServer'
$btnSnapSave      = Get-Ctrl 'btnSnapSave'
$btnSnapOpen      = Get-Ctrl 'btnSnapOpen'
$txtSnapStatus    = Get-Ctrl 'txtSnapStatus'
$dbBadge          = Get-Ctrl 'dbBadge'
$tabSoftware      = Get-Ctrl 'tabSoftware'
$txtSwStation     = Get-Ctrl 'txtSwStation'
$txtSwStatus      = Get-Ctrl 'txtSwStatus'
$dgPackages       = Get-Ctrl 'dgPackages'
$btnSwCopy        = Get-Ctrl 'btnSwCopy'
$btnSwInstall     = Get-Ctrl 'btnSwInstall'
$btnSwOpen        = Get-Ctrl 'btnSwOpen'
$btnSwRemove      = Get-Ctrl 'btnSwRemove'
$txtSwLog         = Get-Ctrl 'txtSwLog'
$txtPkgName       = Get-Ctrl 'txtPkgName'
$txtPkgPath       = Get-Ctrl 'txtPkgPath'
$btnPkgBrowse     = Get-Ctrl 'btnPkgBrowse'
$txtPkgArgs       = Get-Ctrl 'txtPkgArgs'
$chkPkgFolder     = Get-Ctrl 'chkPkgFolder'
$btnPkgAdd        = Get-Ctrl 'btnPkgAdd'
$btnPkgScan       = Get-Ctrl 'btnPkgScan'
$txtSwRoot        = Get-Ctrl 'txtSwRoot'
$btnSwRootSave    = Get-Ctrl 'btnSwRootSave'
$btnDevSoftware   = Get-Ctrl 'btnDevSoftware'
$txtDbVer         = Get-Ctrl 'txtDbVer'
$MainTabs         = Get-Ctrl 'MainTabs'
$tabSql           = Get-Ctrl 'tabSql'
$txtSqlStatus     = Get-Ctrl 'txtSqlStatus'
$btnSqlCopy       = Get-Ctrl 'btnSqlCopy'
$btnSqlRefresh    = Get-Ctrl 'btnSqlRefresh'
$txtSqlDbFull     = Get-Ctrl 'txtSqlDbFull'
$txtSqlDbSub      = Get-Ctrl 'txtSqlDbSub'
$dotBkFull        = Get-Ctrl 'dotBkFull'
$txtBkFull        = Get-Ctrl 'txtBkFull'
$dotBkDiff        = Get-Ctrl 'dotBkDiff'
$txtBkDiff        = Get-Ctrl 'txtBkDiff'
$dotBkLog         = Get-Ctrl 'dotBkLog'
$txtBkLog         = Get-Ctrl 'txtBkLog'
$txtBkPath        = Get-Ctrl 'txtBkPath'
$txtBkDefault     = Get-Ctrl 'txtBkDefault'
$btnBkOpenLast    = Get-Ctrl 'btnBkOpenLast'
$btnBkOpenDefault = Get-Ctrl 'btnBkOpenDefault'
$txtSqlLogSize    = Get-Ctrl 'txtSqlLogSize'
$txtSqlLogUsed    = Get-Ctrl 'txtSqlLogUsed'
$txtSqlDataSize   = Get-Ctrl 'txtSqlDataSize'
$txtSqlDataUsed   = Get-Ctrl 'txtSqlDataUsed'
$txtSqlRecovery   = Get-Ctrl 'txtSqlRecovery'
$txtSqlLogWait    = Get-Ctrl 'txtSqlLogWait'
$txtSqlFileWarn   = Get-Ctrl 'txtSqlFileWarn'
$txtSqlFiles      = Get-Ctrl 'txtSqlFiles'
$txtSqlEdition    = Get-Ctrl 'txtSqlEdition'
$txtSqlBuild      = Get-Ctrl 'txtSqlBuild'
$txtSqlUptime     = Get-Ctrl 'txtSqlUptime'
$txtRefreshEvery  = Get-Ctrl 'txtRefreshEvery'
$txtRefreshHint   = Get-Ctrl 'txtRefreshHint'
$btnTimersSave    = Get-Ctrl 'btnTimersSave'
$txtTimersStatus  = Get-Ctrl 'txtTimersStatus'
$txtDevEvery      = Get-Ctrl 'txtDevEvery'
$tabReaders       = Get-Ctrl 'tabReaders'
$txtRdStatus      = Get-Ctrl 'txtRdStatus'
$btnRdCopy        = Get-Ctrl 'btnRdCopy'
$btnRdRefresh     = Get-Ctrl 'btnRdRefresh'
$txtRdSwipers     = Get-Ctrl 'txtRdSwipers'
$txtRdSwipersSub  = Get-Ctrl 'txtRdSwipersSub'
$txtRdReaders     = Get-Ctrl 'txtRdReaders'
$txtRdReadersSub  = Get-Ctrl 'txtRdReadersSub'
$txtRdSts         = Get-Ctrl 'txtRdSts'
$txtRdStp         = Get-Ctrl 'txtRdStp'
$txtRdPaused      = Get-Ctrl 'txtRdPaused'
$txtRdSearch      = Get-Ctrl 'txtRdSearch'
$btnRdAll         = Get-Ctrl 'btnRdAll'
$btnRdSts         = Get-Ctrl 'btnRdSts'
$btnRdStp         = Get-Ctrl 'btnRdStp'
$chkRdRetired     = Get-Ctrl 'chkRdRetired'
$txtRdCount       = Get-Ctrl 'txtRdCount'
$dgReaders        = Get-Ctrl 'dgReaders'
# COLOR HELPERS + STATUS/TRAY COLOR
function ColorBrush([string]$hex) {
    [Windows.Media.SolidColorBrush][Windows.Media.ColorConverter]::ConvertFromString($hex)
}
function Set-StatusColor {
    param([string]$state)
    switch ($state) {
        'Healthy'   { $statusDot.Fill = ColorBrush '#A6E3A1' }
        'Warning'   { $statusDot.Fill = ColorBrush '#F9E2AF' }
        'Error'     { $statusDot.Fill = ColorBrush '#F38BA8' }
        'Updating'  { $statusDot.Fill = ColorBrush '#89B4FA' }
        default     { $statusDot.Fill = ColorBrush '#CBA6F7' }
    }
}
function Set-TrayIconColor {
    param([string]$state)
    if ($state -eq $script:TrayState) { return }          # only redraw when the colour actually changes
    $color = switch ($state) {
        'Healthy'  { [System.Drawing.Color]::FromArgb(0, 200, 0) }
        'Warning'  { [System.Drawing.Color]::FromArgb(255, 200, 0) }
        'Error'    { [System.Drawing.Color]::FromArgb(255, 80, 80) }
        'Updating' { [System.Drawing.Color]::FromArgb(80, 160, 255) }
        default    { [System.Drawing.Color]::FromArgb(203, 166, 247) }
    }
    $bmp = $null; $g = $null
    try {
        $bmp = New-Object System.Drawing.Bitmap(16, 16)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::FromArgb(30, 30, 46))
        $brush = New-Object System.Drawing.SolidBrush($color)
        $g.FillEllipse($brush, 1, 1, 13, 13)
        $brush.Dispose()
        $hIcon = $bmp.GetHicon()
        $script:TrayIcon.Icon = [System.Drawing.Icon]::FromHandle($hIcon)
        if ($script:TrayHIcon -ne [IntPtr]::Zero) { [void][Win32.NativeIcon]::DestroyIcon($script:TrayHIcon) }   # free the old handle
        $script:TrayHIcon = $hIcon
        $script:TrayState = $state
    } catch {
        Write-Host "Tray icon error: $_"
    } finally {
        if ($g)   { $g.Dispose() }
        if ($bmp) { $bmp.Dispose() }
    }
}
function Get-StatusBrush([string]$status) {
    switch ($status) {
        'Running'      { ColorBrush '#A6E3A1' }
        'Stopped'      { ColorBrush '#F38BA8' }
        'Paused'       { ColorBrush '#F9E2AF' }
        'StartPending' { ColorBrush '#FAB387' }
        'StopPending'  { ColorBrush '#FAB387' }
        'Disabled'     { ColorBrush '#7F849C' }
        'Error'        { ColorBrush '#FAB387' }
        default        { ColorBrush '#6C7086' }
    }
}
# EVENT LOG HELPERS
function Get-ServiceFailureReason {
    param(
        [string]$ServiceName,
        [int]$Minutes = 5
    )
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'System'
            StartTime = (Get-Date).AddMinutes(-$Minutes)
        } -ErrorAction Stop |
        Where-Object {
            $_.Message -match [regex]::Escape($ServiceName)
        } |
        Select-Object -First 3
        if ($events) {
            return ($events | ForEach-Object {
                "EventID $($_.Id): $($_.Message.Split([Environment]::NewLine)[0])"
            }) -join '; '
        }
        return 'No related event found'
    }
    catch {
        return $_.Exception.Message
    }
}
function Get-ServiceEvents {
    param(
        [int]$Hours = 24,
        [int]$MaxEvents = 200
    )
    try {
 $events = Get-WinEvent `
    -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'Service Control Manager'
        StartTime    = (Get-Date).AddHours(-$Hours)
    } `
    -ErrorAction Stop
        $results = foreach ($event in $events) {
            $matchedService = $null
            foreach ($svc in $script:ServiceDefs) {
                if (($event.Message -match [regex]::Escape($svc.Name)) -or
                    ($svc.Display -and $event.Message -match [regex]::Escape($svc.Display))) {
                    $matchedService = $svc.Display
                    break
                }
            }
            $isRelevantLevel = $event.LevelDisplayName -in @(
                'Information'
                'Warning'
                'Error'
                'Critical'
            )
            $isRelevantEvent = $event.Id -in @(
                7031
                7034
                7040
                7045
            )
            if ($matchedService -and ($isRelevantLevel -or $isRelevantEvent)) {
[PSCustomObject]@{
    Time        = $event.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
    Level       = $event.LevelDisplayName
    EventId     = $event.Id
    Source      = $event.ProviderName
    Service     = $matchedService
    Message =
        ($event.Message `
            -replace "`r",' ' `
            -replace "`n",' ')
    FullMessage =
        $event.Message
}
            }
        }
        return $results |
            Sort-Object Time -Descending |
            Select-Object -First $MaxEvents
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound,*') {
            return @()
        }
        throw
    }
}
# SAFE SERVICE QUERY + CONTROL
function Get-SafeServiceStatus([string]$Name) {
    try {
        $s = Get-Service -Name $Name -ErrorAction Stop
        $startType = $s.StartType.ToString()
        $status    = $s.Status.ToString()
        # Startup type check: a stopped service set to Disabled is not a failure, show it as Disabled
        if ($startType -eq 'Disabled' -and $status -eq 'Stopped') { $status = 'Disabled' }
        return [PSCustomObject]@{
            Status    = $status
            StartType = $startType
            Error     = $null
        }
    } catch {
        $notFound = ($_.FullyQualifiedErrorId -like 'NoServiceFoundForGivenName*')
        return [PSCustomObject]@{
            Status    = $(if ($notFound) { 'NotFound' } else { 'Error' })
            StartType = 'Unknown'
            Error     = $_.Exception.Message
        }
    }
}
function Get-ServiceResourceMetrics {
    $metrics = @{}
    foreach ($def in $script:ServiceDefs) {
        $metrics[$def.Name] = [PSCustomObject]@{
            CpuPercent = $null
            MemoryMB   = $null
            ReadMBps   = $null
            WriteMBps  = $null
            ProcessId  = 0
            Note       = 'Service is not running'
        }
    }

    try {
        $serviceProcesses = @(Get-CimInstance -ClassName Win32_Service |
            Where-Object { $_.Name -in $script:ServiceDefs.Name -and $_.State -eq 'Running' -and $_.ProcessId -gt 0 })
        $processIds = @($serviceProcesses.ProcessId | Sort-Object -Unique)
        if ($processIds.Count -eq 0) {
            $script:PreviousProcessSamples = @{}
            return $metrics
        }

        $filter = ($processIds | ForEach-Object { "ProcessId=$_" }) -join ' OR '
        $now = Get-Date
        $processes = @(Get-CimInstance -ClassName Win32_Process -Filter $filter)
        $nextSamples = @{}
        foreach ($process in $processes) {
            $processId = [int]$process.ProcessId
            $nextSamples[$processId] = [PSCustomObject]@{
                Time             = $now
                CpuTime100ns     = [double]$process.KernelModeTime + [double]$process.UserModeTime
                ReadTransferCount  = [double]$process.ReadTransferCount
                WriteTransferCount = [double]$process.WriteTransferCount
                MemoryMB         = [Math]::Round(([double]$process.WorkingSetSize / 1MB), 1)
                CreationDate      = [string]$process.CreationDate
            }
        }

        $processorCount = [Math]::Max(1, [Environment]::ProcessorCount)
        foreach ($service in $serviceProcesses) {
            $processId = [int]$service.ProcessId
            $processSample = $nextSamples[$processId]
            if (-not $processSample) {
                $metrics[$service.Name] = [PSCustomObject]@{
                    CpuPercent = $null; MemoryMB = $null; ReadMBps = $null; WriteMBps = $null
                    ProcessId = $processId; Note = 'Process metrics are unavailable'
                }
                continue
            }

            $previous = $script:PreviousProcessSamples[$processId]
            $cpuPercent = $null
            $readMBps = $null
            $writeMBps = $null
            if ($previous) {
                $elapsed = ($now - $previous.Time).TotalSeconds
                if ($elapsed -gt 0 -and
                    $processSample.CreationDate -eq $previous.CreationDate -and
                    $processSample.CpuTime100ns -ge $previous.CpuTime100ns -and
                    $processSample.ReadTransferCount -ge $previous.ReadTransferCount -and
                    $processSample.WriteTransferCount -ge $previous.WriteTransferCount) {
                    $cpuPercent = [Math]::Round((($processSample.CpuTime100ns - $previous.CpuTime100ns) / 10000000 / $elapsed / $processorCount) * 100, 1)
                    $readMBps = [Math]::Round((($processSample.ReadTransferCount - $previous.ReadTransferCount) / 1MB / $elapsed), 2)
                    $writeMBps = [Math]::Round((($processSample.WriteTransferCount - $previous.WriteTransferCount) / 1MB / $elapsed), 2)
                }
            }
            $metrics[$service.Name] = [PSCustomObject]@{
                CpuPercent = $cpuPercent
                MemoryMB   = $processSample.MemoryMB
                ReadMBps   = $readMBps
                WriteMBps  = $writeMBps
                ProcessId  = $processId
                Note       = if ($null -eq $cpuPercent) { 'Rates available after the next refresh' } else { '' }
            }
        }
        $script:PreviousProcessSamples = $nextSamples
    }
    catch {
        $errorMessage = $_.Exception.Message
        foreach ($def in $script:ServiceDefs) {
            $metrics[$def.Name] = [PSCustomObject]@{
                CpuPercent = $null; MemoryMB = $null; ReadMBps = $null; WriteMBps = $null
                ProcessId = 0; Note = "Metrics unavailable: $errorMessage"
            }
        }
    }
    return $metrics
}
function Start-ServiceSafe([string]$name) {
    try {
        $svc = Get-Service -Name $name -ErrorAction Stop
        if ($svc.StartType.ToString() -eq 'Disabled') {
            return "Error: service is Disabled - change its Startup type to Manual/Automatic first"
        }
        Start-Service -Name $name -ErrorAction Stop
        $script:ExpectedStops.Remove($name)      # it is running again, so the next stop is a real outage
        return "Started"
    } catch {
        return "Error: $($_.Exception.Message)"
    }
}
function Stop-ServiceSafe([string]$name) {
    try {
        $wasRunning = ((Get-Service -Name $name -ErrorAction Stop).Status -eq 'Running')
        Stop-Service -Name $name -ErrorAction Stop
        if ($wasRunning) { $script:ExpectedStops[$name] = $true }   # a stop we asked for is not an outage
        return "Stopped"
    } catch {
        return "Error: $($_.Exception.Message)"
    }
}
function Restart-ServiceSafe([string]$name) {
    try {
        Restart-Service -Name $name -ErrorAction Stop
        return "Restarted"
    } catch {
        return "Error: $($_.Exception.Message)"
    }
}
function Build-ServiceRows {
    $ServicePanel.Children.Clear()
    $script:ServiceRows = @{}
    foreach ($def in $script:ServiceDefs) {
        $card = New-Object Windows.Controls.Border
        $card.Background   = ColorBrush '#313244'
        $card.CornerRadius = New-Object Windows.CornerRadius(8)
        $card.Margin       = New-Object Windows.Thickness(0, 0, 0, 8)
        $card.Padding      = New-Object Windows.Thickness(16, 12, 16, 12)
        $card.Tag          = $def.Group
        $grid = New-Object Windows.Controls.Grid
        # Columns: Dot | Info | Resources | Status | Toggle
        foreach ($w in @('Auto', '*', 'Auto', 'Auto', 'Auto')) {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = if ($w -eq '*') {
                New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star)
            } else { [Windows.GridLength]::Auto }
            $grid.ColumnDefinitions.Add($cd)
        }
        # Status dot
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width  = 12
        $dot.Height = 12
        $dot.Fill   = ColorBrush '#6C7086'
        $dot.Margin = New-Object Windows.Thickness(0,0,14,0)
        $dot.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($dot, 0)
        # Info stack
        $infoStack = New-Object Windows.Controls.StackPanel
        $infoStack.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($infoStack, 1)
        $nameRow = New-Object Windows.Controls.StackPanel
        $nameRow.Orientation = 'Horizontal'
        $dispTb = New-Object Windows.Controls.TextBlock
        $dispTb.Text       = $def.Display
        $dispTb.FontSize   = 14
        $dispTb.FontWeight = 'SemiBold'
        $dispTb.Foreground = ColorBrush '#CDD6F4'
        $dispTb.Margin     = New-Object Windows.Thickness(0,0,8,0)
        $grpBadge = New-Object Windows.Controls.Border
        $grpBadge.Background   = ColorBrush '#45475A'
        $grpBadge.CornerRadius = New-Object Windows.CornerRadius(4)
        $grpBadge.Padding      = New-Object Windows.Thickness(6,1,6,1)
        $grpTb = New-Object Windows.Controls.TextBlock
        $grpTb.Text       = $def.Group
        $grpTb.FontSize   = 10
        $grpTb.Foreground = ColorBrush '#89B4FA'
        $grpBadge.Child   = $grpTb
        $nameRow.Children.Add($dispTb)   | Out-Null
        $nameRow.Children.Add($grpBadge) | Out-Null
        $svcTb = New-Object Windows.Controls.TextBlock
        $svcTb.Text       = "$($def.Name)  |  Startup: checking..."
        $svcTb.FontSize   = 11
        $svcTb.Foreground = ColorBrush '#6C7086'
        $svcTb.Margin     = New-Object Windows.Thickness(0,2,0,0)
        $infoStack.Children.Add($nameRow) | Out-Null
        $infoStack.Children.Add($svcTb)   | Out-Null
        $metricsTb = New-Object Windows.Controls.TextBlock
        $metricsTb.Text = 'CPU --  MEM --  Disk R/W --'
        $metricsTb.FontSize = 11
        $metricsTb.Foreground = ColorBrush '#A6ADC8'
        $metricsTb.VerticalAlignment = 'Center'
        $metricsTb.Margin = New-Object Windows.Thickness(12,0,16,0)
        $metricsTb.ToolTip = 'Process-level metrics: CPU is a share of total system capacity, memory is working set, and disk is read/write I/O rate. Services sharing a process show the same values. Rates need two refresh samples.'
        [Windows.Controls.Grid]::SetColumn($metricsTb, 2)
        # Status text
        $statusTb = New-Object Windows.Controls.TextBlock
        $statusTb.FontSize   = 12
        $statusTb.Foreground = ColorBrush '#6C7086'
        $statusTb.VerticalAlignment = 'Center'
        $statusTb.HorizontalAlignment = 'Right'
        $statusTb.Margin = New-Object Windows.Thickness(0,0,16,0)
        [Windows.Controls.Grid]::SetColumn($statusTb, 3)
        # Monitor on/off switch
        $chk = New-Object Windows.Controls.CheckBox
        $chk.Style     = $window.FindResource('SwitchToggle')
        $chk.Tag       = $def.Name
        $chk.IsChecked = -not $script:DisabledServices.ContainsKey($def.Name)
        $chk.ToolTip   = 'On = monitored and included in Start/Stop/Restart All'
        [Windows.Controls.Grid]::SetColumn($chk, 4)
        $chk.Add_Click({
            $n = [string]$this.Tag
            $d = $script:ServiceRows[$n].Def
            if ($this.IsChecked) { $script:DisabledServices.Remove($n); $label = 'Monitoring On' }
            else                 { $script:DisabledServices[$n] = $true; $label = 'Monitoring Off' }
            Save-Config -RefreshSeconds ($script:RefreshSecs)
            Add-HistoryEntry -ServiceName $d.Display -Group $d.Group -OldStatus '' -NewStatus $label -Note 'Toggled by user'
            Update-ServiceRow $n
            Refresh-Summary
        })
        # Add elements to grid
        $grid.Children.Add($dot)       | Out-Null
        $grid.Children.Add($infoStack) | Out-Null
        $grid.Children.Add($metricsTb) | Out-Null
        $grid.Children.Add($statusTb)  | Out-Null
        $grid.Children.Add($chk)       | Out-Null
        # Add card to panel
        $card.Child = $grid
        $ServicePanel.Children.Add($card) | Out-Null
        $script:ServiceRows[$def.Name] = [PSCustomObject]@{
            Card     = $card
            Dot      = $dot
            MetricsTb = $metricsTb
            StatusTb = $statusTb
            NoteTb   = $svcTb
            Toggle   = $chk
            Def      = $def
        }
    }
}
# HISTORY + SUMMARY + EVENTS
$HistoryGrid.ItemsSource = $script:HistoryList
$EventsGrid.ItemsSource = $script:EventList
function Add-HistoryEntry {
    param(
        [string]$ServiceName,
        [string]$Group,
        [string]$OldStatus,
        [string]$NewStatus,
        [string]$Note
    )
    $entry = [PSCustomObject]@{
        Time        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        ServiceName = $ServiceName
        Group       = $Group
        OldStatus   = $OldStatus
        NewStatus   = $NewStatus
        Note        = $Note
    }
    $script:HistoryList.Insert(0, $entry)
    $statEvents.Text = [string]$script:HistoryList.Count
    # Also keep a daily CSV so history survives a dashboard restart
    try {
        if (-not (Test-Path -LiteralPath $script:HistoryDir)) { New-Item -ItemType Directory -Path $script:HistoryDir -Force | Out-Null }
        $csv = Join-Path $script:HistoryDir ('History_{0}.csv' -f (Get-Date).ToString('yyyy-MM-dd'))
        $entry | Export-Csv -Path $csv -Append -NoTypeInformation -Encoding UTF8
    } catch {}
}
function Refresh-Summary {
    $running = 0
    $stopped = 0
    $other   = 0
    $disabled = 0
    foreach ($def in $script:ServiceDefs) {
        if (Test-Skipped $def.Name) { continue }
        $st = $script:ServiceCache[$def.Name]
        if (-not $st) { $st = Get-SafeServiceStatus $def.Name }
        switch ($st.Status) {
            'Running' { $running++ }
            'Stopped' { $stopped++ }
            'Disabled' { $disabled++ }
            default   { $other++ }
        }
    }
    $statRunning.Text  = [string]$running
    $statStopped.Text  = [string]$stopped
    $statOther.Text    = [string]$other
    $statLastScan.Text = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    if ($stopped -gt 0) {
        Set-StatusColor 'Warning'
        Set-TrayIconColor 'Warning'
        $statusBar.Text = "Some services are stopped."
    }
    elseif ($other -gt 0) {
        Set-StatusColor 'Error'
        Set-TrayIconColor 'Error'
        $statusBar.Text = "Some services are in non-standard state."
    }
    else {
        Set-StatusColor 'Healthy'
        Set-TrayIconColor 'Healthy'
        $statusBar.Text = "All services healthy."
    }
    if ($disabled -gt 0) { $statusBar.Text += " ($disabled disabled)" }
    if ($script:AutoOff.Count -gt 0) { $statusBar.Text += " ($($script:AutoOff.Count) not installed)" }
    $statusBarRight.Text = "Last scan: $($statLastScan.Text)"
    $GroupHealthPanel.Items.Clear()
    foreach ($group in ($script:ServiceDefs.Group | Sort-Object -Unique)) {
        $defs = @($script:ServiceDefs | Where-Object { $_.Group -eq $group -and -not (Test-Skipped $_.Name) })
        $gRunning = 0
        $gTotal   = $defs.Count
        foreach ($d in $defs) {
            $st = $script:ServiceCache[$d.Name]
            if (-not $st) { $st = Get-SafeServiceStatus $d.Name }
            if ($st.Status -eq 'Running') { $gRunning++ }
        }
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = if ($gTotal -eq 0) { "${group}: monitoring off" } else { "${group}: ${gRunning} / ${gTotal} running" }
        $tb.Foreground = ColorBrush '#CDD6F4'
        $tb.Margin = New-Object Windows.Thickness(0,2,0,2)
        $GroupHealthPanel.Items.Add($tb) | Out-Null
    }
}
function Add-HistoryEntry {
    param(
        [string]$ServiceName,
        [string]$Group,
        [string]$OldStatus,
        [string]$NewStatus,
        [string]$Note
    )
    $entry = [PSCustomObject]@{
        Time        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        ServiceName = $ServiceName
        Group       = $Group
        OldStatus   = $OldStatus
        NewStatus   = $NewStatus
        Note        = $Note
    }
    $script:HistoryList.Insert(0, $entry)
    $statEvents.Text = [string]$script:HistoryList.Count
}
function Refresh-EventsGrid {
    $events = @(Get-ServiceEvents)
    $script:EventList.Clear()
    foreach ($event in $events) {
        $script:EventList.Add($event)
    }
}
$btnRefreshEvents.Add_Click({
    try {
        Refresh-EventsGrid
        $statusBar.Text = "Event list refreshed."
    }
    catch {
        $statusBar.Text = "Could not refresh event list: $($_.Exception.Message)"
    }
})
$btnClearEvents.Add_Click({
    $script:EventList.Clear()
    $statusBar.Text =
        "Event view cleared."
})
# EMAIL ALERTS (SMTP)
function Get-SmtpSecurePassword {
    $enc = [string]$script:SmtpConfig['PasswordEnc']
    if (-not $enc) { return $null }
    try { return (ConvertTo-SecureString $enc) } catch { return $null }   # fails if saved by another user/machine
}
# Returns $null on success, or an error message
function Send-SmtpMessage {
    param([string]$Subject, [string]$Body)
    $c = $script:SmtpConfig
    $msg    = $null
    $client = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $msg = New-Object System.Net.Mail.MailMessage
        $msg.From = New-Object System.Net.Mail.MailAddress([string]$c['From'])
        foreach ($addr in ([string]$c['To'] -split '[;,]')) {
            if ($addr.Trim()) { $msg.To.Add($addr.Trim()) }
        }
        $msg.Subject = $Subject
        $msg.Body    = $Body
        $client = New-Object System.Net.Mail.SmtpClient([string]$c['Server'], [int]$c['Port'])
        $client.EnableSsl = [bool]$c['UseSsl']
        $client.Timeout   = 10000
        if ([string]$c['Username']) {
            $secure = Get-SmtpSecurePassword
            if (-not $secure) { return 'Saved password could not be read - re-enter it and save again.' }
            $client.UseDefaultCredentials = $false
            $client.Credentials = New-Object System.Net.NetworkCredential([string]$c['Username'], $secure)
        }
        $client.Send($msg)
        return $null
    } catch {
        $ex = $_.Exception
        $m  = $ex.Message
        if ($ex.InnerException) { $m += ' - ' + $ex.InnerException.Message }
        return $m
    } finally {
        if ($msg)    { $msg.Dispose() }
        if ($client) { $client.Dispose() }
    }
}
# Called when a service that was Running is found offline (and we did not stop it ourselves)
function Register-OfflineEvent {
    param($Def, [string]$NewStatus)
    $c      = $script:SmtpConfig
    $now    = Get-Date
    $cutoff = $now.AddMinutes(-[int]$c['WindowMinutes'])
    $prev   = @()
    if ($script:OfflineEvents.ContainsKey($Def.Name)) {
        $prev = @($script:OfflineEvents[$Def.Name] | Where-Object { $_ -ge $cutoff })
    }
    $events = @($prev) + @($now)
    $script:OfflineEvents[$Def.Name] = $events

    if (-not [bool]$c['Enabled']) { return }
    if ($events.Count -lt [int]$c['Threshold']) { return }
    if ($script:LastAlertSent.ContainsKey($Def.Name)) {
        $mins = ($now - $script:LastAlertSent[$Def.Name]).TotalMinutes
        if ($mins -lt [int]$c['CooldownMinutes']) { return }
    }

    $subject = "[EMBED] $($Def.Display) went offline $($events.Count) times in $($c['WindowMinutes']) min ($env:COMPUTERNAME)"
    $lines = @(
        "EMBED Services Dashboard alert",
        "",
        "Server:          $env:COMPUTERNAME",
        "Service:         $($Def.Display) ($($Def.Name))",
        "Current status:  $NewStatus",
        "Offline events:  $($events.Count) in the last $($c['WindowMinutes']) minutes (alert threshold: $($c['Threshold']))",
        "",
        "Went offline at:"
    )
    foreach ($e in $events) { $lines += ("  - " + $e.ToString('yyyy-MM-dd HH:mm:ss')) }
    $recent = @($script:HistoryList | Where-Object { $_.ServiceName -eq $Def.Display } | Select-Object -First 8)
    if ($recent.Count -gt 0) {
        $lines += ""
        $lines += "Recent history for this service:"
        foreach ($h in $recent) {
            $lines += ("  {0}   {1} -> {2}   {3}" -f $h.Time, $h.OldStatus, $h.NewStatus, $h.Note)
        }
    }
    $lines += ""
    $lines += "Check the service logs and Windows Event Viewer on this server for the underlying cause."

    $err = Send-SmtpMessage -Subject $subject -Body ($lines -join "`r`n")
    if ($err) {
        Add-HistoryEntry -ServiceName $Def.Display -Group $Def.Group -OldStatus '' -NewStatus 'Alert Failed' -Note $err
    } else {
        $script:LastAlertSent[$Def.Name] = $now
        Add-HistoryEntry -ServiceName $Def.Display -Group $Def.Group -OldStatus '' -NewStatus 'Alert Sent' -Note "Email to $($c['To'])"
    }
}
# ------------------------------------------------------------
# DEVICES (RDP / IP CHECKER)
# ------------------------------------------------------------
$dgDevices.ItemsSource = $script:Devices
function Save-AllConfig { Save-Config -RefreshSeconds ($script:RefreshSecs) }
function New-DeviceObject([string]$Name, [string]$LastIP, [string]$LastSeen) {
    [PSCustomObject]@{
        Name        = $Name
        Status      = 'Not checked'
        CurrentIP   = ''
        LastKnownIP = $LastIP
        LastSeen    = $LastSeen
        Detail      = ''
    }
}
# Runs in a background runspace so the window never freezes.
# Per device: look up the name, then ping + test the RDP port (3389) on the IP that was found.
# If the name does not resolve, the last known IP is tried instead.
$script:DeviceScanScript = {
    param($targets)
    $rdpPort = 3389
    $dns = @{}
    foreach ($t in $targets) {
        try { $dns[$t.Name] = [System.Net.Dns]::GetHostAddressesAsync($t.Name) } catch { $dns[$t.Name] = $null }
    }
    $dnsTasks = @($dns.Values | Where-Object { $_ })
    if ($dnsTasks.Count -gt 0) {
        try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$dnsTasks, 4000) } catch {}
    }
    $probes = @()
    foreach ($t in $targets) {
        $resolved = ''
        $task = $dns[$t.Name]
        if ($task -and $task.Status -eq 'RanToCompletion') {
            $v4 = @($task.Result | Where-Object { $_.AddressFamily -eq 'InterNetwork' })
            if ($v4.Count -gt 0) { $resolved = $v4[0].ToString() }
        }
        $probeIp = $resolved
        if (-not $probeIp) { $probeIp = [string]$t.LastIP }
        $p = @{ Name = $t.Name; Resolved = $resolved; ProbeIp = $probeIp; Ping = $null; Tcp = $null; Client = $null }
        if ($probeIp) {
            try { $p.Ping = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($probeIp, 1500) } catch {}
            try { $p.Client = New-Object System.Net.Sockets.TcpClient; $p.Tcp = $p.Client.ConnectAsync($probeIp, $rdpPort) } catch {}
        }
        $probes += $p
    }
    $probeTasks = @()
    foreach ($p in $probes) {
        if ($p.Ping) { $probeTasks += $p.Ping }
        if ($p.Tcp)  { $probeTasks += $p.Tcp }
    }
    if ($probeTasks.Count -gt 0) {
        try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$probeTasks, 3000) } catch {}
    }
    foreach ($p in $probes) {
        $pingOk  = $false
        $rdpOpen = $false
        if ($p.Ping -and $p.Ping.Status -eq 'RanToCompletion') { $pingOk = ($p.Ping.Result.Status -eq 'Success') }
        if ($p.Tcp  -and $p.Tcp.Status  -eq 'RanToCompletion') { $rdpOpen = [bool]$p.Client.Connected }
        if ($p.Client) { try { $p.Client.Close() } catch {} }
        $responding = ($pingOk -or $rdpOpen)
        if ($p.Resolved) {
            if ($rdpOpen) {
                $status = 'Online'
                $detail = 'Ping and RDP OK'
                if (-not $pingOk) { $detail = 'RDP OK (ping blocked)' }
            } elseif ($pingOk) {
                $status = 'Online (no RDP)'
                $detail = 'Answers ping, but RDP port 3389 is closed'
            } else {
                $status = 'Offline'
                $detail = "No reply from $($p.Resolved)"
            }
        } elseif ($p.ProbeIp) {
            if ($responding) {
                $status = 'Online (no DNS)'
                $detail = "Name did not resolve, but last known IP $($p.ProbeIp) answers"
            } else {
                $status = 'Offline'
                $detail = "Name did not resolve and last known IP $($p.ProbeIp) is not answering"
            }
        } else {
            $status = 'Unresolved'
            $detail = 'Name did not resolve and no IP is stored yet'
        }
        [PSCustomObject]@{
            Name = $p.Name; Status = $status; Detail = $detail
            ResolvedIP = $p.Resolved; ProbeIP = $p.ProbeIp; Responding = $responding
        }
    }
}
function Start-DeviceScan {
    if ($script:DeviceScan) { return $false }          # a check is already running
    if ($script:Devices.Count -eq 0) { return $false }
    try {
        $targets = @($script:Devices | ForEach-Object { @{ Name = $_.Name; LastIP = $_.LastKnownIP } })
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:DeviceScanScript.ToString()).AddArgument($targets)
        $script:DeviceScan = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
        $txtDevStatus.Text = 'Checking devices...'
        return $true
    } catch {
        $script:DeviceScan = $null
        $txtDevStatus.Text = "Could not start device check: $($_.Exception.Message)"
        return $false
    }
}
function Complete-DeviceScan {
    $scan = $script:DeviceScan
    $script:DeviceScan = $null
    $results = @()
    try { $results = @($scan.PS.EndInvoke($scan.Handle)) }
    catch { $txtDevStatus.Text = "Device check failed: $($_.Exception.Message)"; return }
    finally { try { $scan.PS.Dispose(); $scan.RS.Close(); $scan.RS.Dispose() } catch {} }
    $needSave = $false
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    foreach ($r in $results) {
        $dev = $script:Devices | Where-Object { $_.Name -eq $r.Name } | Select-Object -First 1
        if (-not $dev) { continue }                    # removed while the check was running
        $wasChecked = ($dev.Status -ne 'Not checked')
        $wasOnline  = ($dev.Status -like 'Online*')
        $isOnline   = ($r.Status -like 'Online*')
        $dev.Status    = $r.Status
        $dev.CurrentIP = [string]$r.ResolvedIP
        $dev.Detail    = $r.Detail
        if ($r.Responding) {
            $dev.LastSeen = $now
            if ($r.ResolvedIP -and $dev.LastKnownIP -ne $r.ResolvedIP) {
                $dev.LastKnownIP = $r.ResolvedIP       # remember the IP so we can still ping it if the device drops off
                $needSave = $true
            }
        }
        if ($wasChecked -and ($wasOnline -ne $isOnline)) {
            $was = 'Offline'; if ($wasOnline) { $was = 'Online' }
            $now2 = 'Offline'; if ($isOnline) { $now2 = 'Online' }
            Add-HistoryEntry -ServiceName $dev.Name -Group 'Device' -OldStatus $was -NewStatus $now2 -Note $r.Detail
            $needSave = $true                          # also stores Last seen at the moment it dropped
        }
    }
    $dgDevices.Items.Refresh()
    if ($needSave) { Save-AllConfig }
    $txtDevStatus.Text = "Last check: $((Get-Date).ToString('HH:mm:ss'))"
}
function Get-DeviceTarget($dev) {
    if ($dev.CurrentIP)   { return [string]$dev.CurrentIP }
    if ($dev.LastKnownIP) { return [string]$dev.LastKnownIP }
    return [string]$dev.Name
}
function Add-DeviceFromUi {
    $name = $txtDevName.Text.Trim()
    if (-not $name) { return }
    if ($name -notmatch '^[A-Za-z0-9._-]+$') { $txtDevStatus.Text = 'Use letters, numbers, dots, dashes or underscores only.'; return }
    if (@($script:Devices | Where-Object { $_.Name -eq $name }).Count -gt 0) { $txtDevStatus.Text = "$name is already in the list."; return }
    $script:Devices.Add((New-DeviceObject $name '' ''))
    $txtDevName.Clear()
    Save-AllConfig
    $txtDevStatus.Text = "Added $name"
    [void](Start-DeviceScan)
}
$btnDevAdd.Add_Click({ Add-DeviceFromUi })
$txtDevName.Add_KeyDown({ if ($_.Key -eq 'Return') { Add-DeviceFromUi } })
$btnDevCheck.Add_Click({
    if ($script:Devices.Count -eq 0) { $txtDevStatus.Text = 'Add a device first.'; return }
    if (-not (Start-DeviceScan)) { $txtDevStatus.Text = 'A check is already running...' }
})
$btnDevConnect.Add_Click({
    $dev = $dgDevices.SelectedItem
    if (-not $dev) { $txtDevStatus.Text = 'Select a device first.'; return }
    if ($dev.Status -eq 'Offline' -or $dev.Status -eq 'Unresolved') {
        $ans = [System.Windows.MessageBox]::Show("$($dev.Name) looks offline. Try connecting anyway?", 'Remote Desktop', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
    }
    Start-Process -FilePath 'mstsc.exe' -ArgumentList "/v:$(Get-DeviceTarget $dev)"
})
$btnDevPing.Add_Click({
    $dev = $dgDevices.SelectedItem
    if (-not $dev) { $txtDevStatus.Text = 'Select a device first.'; return }
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/k ping -t $(Get-DeviceTarget $dev)"
})
$btnDevRemove.Add_Click({
    $dev = $dgDevices.SelectedItem
    if (-not $dev) { $txtDevStatus.Text = 'Select a device first.'; return }
    $ans = [System.Windows.MessageBox]::Show("Remove $($dev.Name) from the list?", 'Remove device', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    [void]$script:Devices.Remove($dev)
    Save-AllConfig
    $txtDevStatus.Text = 'Device removed.'
})
# ------------------------------------------------------------
# DISCOVER (find PCs on this server's network)
# ------------------------------------------------------------
$dgDisc.ItemsSource = $script:DiscList
# Runs in a background runspace. Pings and tests the RDP port (3389) on every address of each local network
# (never more than 254 addresses per network), looks up names, and reads the GURU reader / cash device IPs
# (read-only) so those can be hidden.
$script:DiscoverScript = {
    param($sqlServer)
    function ConvertTo-IpString([long]$n) {
        '{0}.{1}.{2}.{3}' -f (($n -shr 24) -band 255), (($n -shr 16) -band 255), (($n -shr 8) -band 255), ($n -band 255)
    }
    function Read-FirstColumn([string]$ConnStr, [string]$Sql) {
        $list = @()
        $c = New-Object System.Data.SqlClient.SqlConnection $ConnStr
        try {
            $c.Open()
            $cmd = $c.CreateCommand()
            $cmd.CommandText    = $Sql
            $cmd.CommandTimeout = 10
            $rd = $cmd.ExecuteReader()
            while ($rd.Read()) {
                if (-not $rd.IsDBNull(0)) {
                    $v = ([string]$rd.GetValue(0)).Trim()
                    if ($v) { $list += $v }
                }
            }
            $rd.Close()
        } finally { $c.Dispose() }
        return $list
    }

    # 1) which networks is this server on?
    $own  = @{}
    $nets = @{}
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up') { continue }
        if ($nic.NetworkInterfaceType -eq 'Loopback' -or $nic.NetworkInterfaceType -eq 'Tunnel') { continue }
        foreach ($ua in $nic.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
            $ipText = $ua.Address.ToString()
            if ($ipText.StartsWith('169.254.') -or $ipText.StartsWith('127.')) { continue }
            $own[$ipText] = $true
            $b = $ua.Address.GetAddressBytes()
            $ipInt  = ([long]$b[0] -shl 24) -bor ([long]$b[1] -shl 16) -bor ([long]$b[2] -shl 8) -bor [long]$b[3]
            $prefix = [int]$ua.PrefixLength
            if ($prefix -lt 24) { $prefix = 24 }        # never sweep more than 254 addresses per network
            if ($prefix -gt 30) { continue }
            $size = [long]1 -shl (32 - $prefix)
            $net  = $ipInt - ($ipInt % $size)
            $nets["$net/$prefix"] = @{ Net = $net; Size = $size; Prefix = $prefix }
        }
    }
    $targets  = @()
    $netNames = @()
    foreach ($n in $nets.Values) {
        $netNames += ('{0}/{1}' -f (ConvertTo-IpString $n.Net), $n.Prefix)
        for ($i = 1; $i -lt ($n.Size - 1); $i++) {
            $addr = ConvertTo-IpString ($n.Net + $i)
            if (-not $own.ContainsKey($addr)) { $targets += $addr }
        }
    }
    if ($targets.Count -gt 1020) { $targets = $targets[0..1019] }

    # 2) ping + RDP port on every address, all at once
    $probes = @()
    foreach ($ip in $targets) {
        $p = @{ Ip = $ip; Ping = $null; Tcp = $null; Client = $null }
        try { $p.Ping = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($ip, 1500) } catch {}
        try { $p.Client = New-Object System.Net.Sockets.TcpClient; $p.Tcp = $p.Client.ConnectAsync($ip, 3389) } catch {}
        $probes += $p
    }
    $tasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
    foreach ($p in $probes) {
        if ($p.Ping) { $tasks.Add($p.Ping) }
        if ($p.Tcp)  { $tasks.Add($p.Tcp) }
    }
    if ($tasks.Count -gt 0) {
        try { [void][System.Threading.Tasks.Task]::WaitAll($tasks.ToArray(), 4000) } catch {}
    }
    $hostsOut = @()
    foreach ($p in $probes) {
        $pingOk  = $false
        $rdpOpen = $false
        if ($p.Ping -and $p.Ping.Status -eq 'RanToCompletion') { $pingOk = ($p.Ping.Result.Status -eq 'Success') }
        if ($p.Tcp  -and $p.Tcp.Status  -eq 'RanToCompletion') { $rdpOpen = [bool]$p.Client.Connected }
        if ($p.Client) { try { $p.Client.Close() } catch {} }
        if ($pingOk -or $rdpOpen) { $hostsOut += @{ Ip = $p.Ip; Rdp = $rdpOpen; Name = '' } }
    }

    # 3) names of the ones that answered
    $dnsTasks = @{}
    foreach ($h in $hostsOut) {
        try { $dnsTasks[$h.Ip] = [System.Net.Dns]::GetHostEntryAsync($h.Ip) } catch {}
    }
    if ($dnsTasks.Count -gt 0) {
        try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($dnsTasks.Values), 4000) } catch {}
    }
    foreach ($h in $hostsOut) {
        $tk = $dnsTasks[$h.Ip]
        if ($tk -and $tk.Status -eq 'RanToCompletion') {
            $hn = [string]$tk.Result.HostName
            if ($hn -and $hn -ne $h.Ip) { $h.Name = $hn }
        }
    }

    # 4) GURU reader and cash-device IPs (read-only), so they can be hidden
    $readerSet = @{}
    $sqlNote   = ''
    try {
        $base    = "Server=$sqlServer;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=5"
        $dbNames = @(Read-FirstColumn $base 'SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0')
        foreach ($db in $dbNames) {
            foreach ($sql in @('SELECT IPAddress FROM dbo.Reader_Units', 'SELECT IP_Address FROM dbo.Cash_Infinity_Settings')) {
                try {
                    foreach ($v in @(Read-FirstColumn "$base;Initial Catalog=$db" $sql)) { $readerSet[$v] = $true }
                } catch {}
            }
        }
    } catch { $sqlNote = $_.Exception.Message }

    $final = @()
    foreach ($h in $hostsOut) {
        $final += [PSCustomObject]@{ Ip = $h.Ip; Name = $h.Name; Rdp = $h.Rdp; Reader = $readerSet.ContainsKey($h.Ip) }
    }
    [PSCustomObject]@{ Networks = ($netNames -join ', '); Hosts = $final; ReaderCount = $readerSet.Count; SqlNote = $sqlNote }
}
# Keys used to recognise a host: its name (full and short form), or its IP when it has no name
function Get-HostKeys([string]$Name, [string]$Ip) {
    $keys = @()
    if ($Name) {
        $n = $Name.ToLower()
        $keys += $n
        if ($n.Contains('.')) { $keys += $n.Split('.')[0] }
    } else {
        $keys += $Ip
    }
    return $keys
}
function Get-KnownDeviceKeys {
    $k = @{}
    foreach ($d in $script:Devices) {
        foreach ($x in @(Get-HostKeys ([string]$d.Name) '')) { $k[$x] = $true }
        foreach ($ip in @($d.CurrentIP, $d.LastKnownIP)) { if ($ip) { $k[[string]$ip] = $true } }
    }
    return $k
}
function Get-DiscoverCandidates([bool]$RdpOnly, [bool]$HideReaders, [string]$Query) {
    $known = Get-KnownDeviceKeys
    $out = @()
    foreach ($h in @($script:DiscResults)) {
        if (-not $h) { continue }
        if ($HideReaders -and $h.Reader) { continue }
        if ($RdpOnly -and -not $h.RdpOk) { continue }
        $hidden = $false
        foreach ($k in @(Get-HostKeys $h.HostName $h.Ip)) {
            if ($script:IgnoredHosts.ContainsKey($k) -or $known.ContainsKey($k)) { $hidden = $true }
        }
        if ($hidden) { continue }
        if ($Query -and ($h.Name.IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -lt 0) -and ($h.Ip.IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
        $out += $h
    }
    return $out
}
function Update-DiscoverList {
    $script:DiscList.Clear()
    foreach ($h in @(Get-DiscoverCandidates ([bool]$chkDscRdp.IsChecked) ([bool]$chkDscReaders.IsChecked) ($txtDscSearch.Text.Trim()))) {
        $script:DiscList.Add($h)
    }
    $txtDscCount.Text = "$($script:DiscList.Count) shown of $(@($script:DiscResults).Count) found"
}
# Adds the given discovered hosts to the Devices list (hostname + the IP they answered on). Returns "NAME (IP)" for each one added.
function Add-DiscoveredDevices($items) {
    $now   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $added = @()
    foreach ($h in @($items)) {
        $nm = [string]$h.HostName
        if (-not $nm -or $nm -notmatch '^[A-Za-z0-9._-]+$') { $nm = [string]$h.Ip }
        if (@($script:Devices | Where-Object { $_.Name -eq $nm }).Count -gt 0) { continue }
        $script:Devices.Add((New-DeviceObject $nm ([string]$h.Ip) $now))    # the IP is stored right away
        $added += "$nm ($($h.Ip))"
    }
    if ($added.Count -gt 0) {
        Save-AllConfig
        [void](Start-DeviceScan)
    }
    return $added
}
function Start-DiscoverScan {
    if ($script:DiscoverScan) { return }
    $btnDscScan.IsEnabled = $false
    $txtDscStatus.Text = 'Scanning... this takes about 10-20 seconds.'
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:DiscoverScript.ToString()).AddArgument($script:GuruSqlServer)
        $script:DiscoverScan = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
    } catch {
        $script:DiscoverScan = $null
        $btnDscScan.IsEnabled = $true
        $txtDscStatus.Text = "Could not start the scan: $($_.Exception.Message)"
    }
}
function Complete-DiscoverScan {
    $scan = $script:DiscoverScan
    $script:DiscoverScan = $null
    $btnDscScan.IsEnabled = $true
    $res = $null
    try { $res = @($scan.PS.EndInvoke($scan.Handle)) | Select-Object -First 1 }
    catch { $txtDscStatus.Text = "Scan failed: $($_.Exception.Message)"; return }
    finally { try { $scan.PS.Dispose(); $scan.RS.Close(); $scan.RS.Dispose() } catch {} }
    if (-not $res) { $txtDscStatus.Text = 'The scan returned nothing.'; return }
    $found = @()
    foreach ($h in @($res.Hosts)) {
        if (-not $h) { continue }
        $name = [string]$h.Name
        $notes = @()
        if ($h.Reader)       { $notes += 'GURU reader / cash device' }
        elseif (-not $h.Rdp) { $notes += 'Remote Desktop closed' }
        if (-not $name)      { $notes += 'no name found' }
        $shown = '(no name)'; if ($name) { $shown = $name }
        $rdpText = 'Closed';  if ($h.Rdp) { $rdpText = 'Open' }
        $found += [PSCustomObject]@{
            Selected = $false; Name = $shown; HostName = $name; Ip = [string]$h.Ip
            Rdp = $rdpText; RdpOk = [bool]$h.Rdp; Reader = [bool]$h.Reader; Note = ($notes -join '; ')
        }
    }
    $script:DiscResults = @($found | Sort-Object { [version]$_.Ip })
    $msg = "Scanned $($res.Networks). Found $($script:DiscResults.Count) responding."
    if ($res.SqlNote) { $msg += " GURU reader list unavailable ($($res.SqlNote))." }
    else              { $msg += " $($res.ReaderCount) known GURU reader/cash IPs checked." }
    $txtDscStatus.Text = $msg
    Update-DiscoverList
    if ($script:AutoAddDiscovered) {
        $new = @(Get-DiscoverCandidates $true $true '')          # PCs with Remote Desktop open, not readers, not ignored, not already listed
        if ($new.Count -gt 0) {
            $names = @(Add-DiscoveredDevices $new)
            Update-DiscoverList
            $shownNames = ($names | Select-Object -First 4) -join ', '
            if ($names.Count -gt 4) { $shownNames += ", +$($names.Count - 4) more" }
            $txtDscStatus.Text = "$msg Added $($names.Count): $shownNames"
        }
    }
}
$btnDevDiscover.Add_Click({ $pnlRemote.Visibility = 'Collapsed'; $pnlDiscover.Visibility = 'Visible'; Update-DiscoverList })
$btnDscClose.Add_Click({ $pnlDiscover.Visibility = 'Collapsed' })
$btnDscScan.Add_Click({ Start-DiscoverScan })
$chkDscRdp.Add_Click({ Update-DiscoverList })
$chkDscReaders.Add_Click({ Update-DiscoverList })
$txtDscSearch.Add_TextChanged({ Update-DiscoverList })
$btnDscAdd.Add_Click({
    $sel = @($script:DiscList | Where-Object { $_.Selected })
    if ($sel.Count -eq 0) { $txtDscStatus.Text = 'Tick at least one device first.'; return }
    $names = @(Add-DiscoveredDevices $sel)
    Update-DiscoverList
    $txtDscStatus.Text = "Added $($names.Count) device(s) to the Devices list."
})
$btnDscIgnore.Add_Click({
    $sel = @($script:DiscList | Where-Object { $_.Selected })
    if ($sel.Count -eq 0) { $txtDscStatus.Text = 'Tick at least one device first.'; return }
    foreach ($h in $sel) {
        foreach ($k in @(Get-HostKeys ([string]$h.HostName) ([string]$h.Ip))) { $script:IgnoredHosts[$k] = $true }
    }
    Save-AllConfig
    Update-DiscoverList
    $txtDscStatus.Text = "Ignoring $($sel.Count) device(s) from now on."
})
# ------------------------------------------------------------
# UPDATE SERVICE ROWS
# ------------------------------------------------------------
function Update-ServiceResourceMetricDisplay {
    param($Row, $Metrics)
    if (-not $Metrics) {
        $Row.MetricsTb.Text = 'CPU --  MEM --  Disk R/W --'
        return
    }

    $cpuText = if ($null -eq $Metrics.CpuPercent) { '--' } else { '{0:N1}%' -f $Metrics.CpuPercent }
    $memoryText = if ($null -eq $Metrics.MemoryMB) { '--' } else { '{0:N1} MB' -f $Metrics.MemoryMB }
    $readText = if ($null -eq $Metrics.ReadMBps) { '--' } else { '{0:N2}' -f $Metrics.ReadMBps }
    $writeText = if ($null -eq $Metrics.WriteMBps) { '--' } else { '{0:N2}' -f $Metrics.WriteMBps }
    $Row.MetricsTb.Text = "CPU $cpuText  MEM $memoryText  Disk R/W $readText/$writeText MB/s"
    $tooltip = 'Process-level metrics: CPU is a share of total system capacity, memory is working set, and disk is read/write I/O rate. Services sharing a process show the same values.'
    if ($Metrics.ProcessId -gt 0) { $tooltip += " Process ID: $($Metrics.ProcessId)." }
    if ($Metrics.Note) { $tooltip += " $($Metrics.Note)" }
    $Row.MetricsTb.ToolTip = $tooltip
}
function Update-ServiceRow {
    param([string]$Name)
    $row = $script:ServiceRows[$Name]
    if (-not $row) { return }
    $def = $row.Def
    $st  = $script:ServiceCache[$def.Name]
    if (-not $st) {
        $st = Get-SafeServiceStatus $def.Name
        $script:ServiceCache[$def.Name] = $st
    }
    Update-ServiceResourceMetricDisplay $row $script:ServiceResourceMetrics[$def.Name]
    $wasAuto = $script:AutoOff.ContainsKey($def.Name)

    # Not installed on this machine: switch the toggle off automatically and say why
    if ($st.Status -eq 'NotFound') {
        $script:AutoOff[$def.Name] = 'Service not found'
        if (-not $wasAuto) {
            Add-HistoryEntry -ServiceName $def.Display -Group $def.Group -OldStatus '' -NewStatus 'Auto Off' -Note 'Service not found - monitoring switched off automatically'
        }
        $row.Toggle.IsChecked = $false
        $row.Toggle.IsEnabled = $false
        $row.Toggle.ToolTip   = 'Service not found on this machine. Re-checked on every refresh.'
        $row.StatusTb.Text    = 'Service not found'
        $row.NoteTb.Text      = "{0}  |  Not installed on this machine - switched off automatically" -f $def.Name
        $row.Dot.Fill         = ColorBrush '#6C7086'
        $row.Card.Opacity     = 0.5
        $script:PreviousStates.Remove($def.Name)
        return
    }

    # Service reappeared: give the toggle back (respecting any manual off)
    if ($wasAuto) {
        $script:AutoOff.Remove($def.Name)
        $row.Toggle.IsEnabled = $true
        $row.Toggle.IsChecked = -not $script:DisabledServices.ContainsKey($def.Name)
        $row.Toggle.ToolTip   = 'On = monitored and included in Start/Stop/Restart All'
        Add-HistoryEntry -ServiceName $def.Display -Group $def.Group -OldStatus 'Auto Off' -NewStatus 'Auto On' -Note 'Service found - monitoring resumed'
    }

    $row.NoteTb.Text = "{0}  |  Startup: {1}" -f $def.Name, $st.StartType

    # Switched off by the user
    if ($script:DisabledServices.ContainsKey($def.Name)) {
        $row.StatusTb.Text = 'Monitoring off'
        $row.Dot.Fill      = ColorBrush '#6C7086'
        $row.Card.Opacity  = 0.5
        $script:PreviousStates.Remove($def.Name)
        return
    }

    $row.Card.Opacity = 1.0
    $old = $script:PreviousStates[$def.Name]
    $script:PreviousStates[$def.Name] = $st.Status
    $row.StatusTb.Text = $st.Status
    $row.Dot.Fill      = Get-StatusBrush $st.Status
    if ($old -and $old -ne $st.Status) {
        Add-HistoryEntry -ServiceName $def.Display -Group $def.Group -OldStatus $old -NewStatus $st.Status -Note ''
        # Running -> offline counts toward the email alert (unless we stopped it from the dashboard)
        if ($old -eq 'Running' -and ($st.Status -in @('Stopped', 'StopPending', 'Disabled', 'Error'))) {
            if ($script:ExpectedStops.ContainsKey($def.Name)) { $script:ExpectedStops.Remove($def.Name) }
            else { Register-OfflineEvent $def $st.Status }
        }
    }
}
function Update-AllServices {
    $script:ServiceResourceMetrics = Get-ServiceResourceMetrics
    $script:ServiceCache = @{}
    foreach ($def in $script:ServiceDefs) {
        $script:ServiceCache[$def.Name] = Get-SafeServiceStatus $def.Name
        Update-ServiceRow $def.Name
    }
    Refresh-Summary
}
# ------------------------------------------------------------
# FILTERING
# ------------------------------------------------------------
function Apply-Filter {
    param([string]$group)
    $script:ActiveFilter = $group
    foreach ($def in $script:ServiceDefs) {
        $row = $script:ServiceRows[$def.Name]
        if (-not $row) { continue }
        if ($group -eq 'All' -or $def.Group -eq $group) {
            $row.Card.Visibility = [System.Windows.Visibility]::Visible
        } else {
            $row.Card.Visibility = [System.Windows.Visibility]::Collapsed
        }
    }
}
# ------------------------------------------------------------
# CONFIG + SLIDER INITIALIZATION
# ------------------------------------------------------------
$config = Load-Config
$secs = 30
$rp = $config.PSObject.Properties['RefreshSeconds']
if ($rp) { $secs = [int]$rp.Value }
if ($secs -lt 10) { $secs = 10 }
if ($secs -gt 5400) { $secs = 5400 }
$dp = $config.PSObject.Properties['DisabledServices']
if ($dp -and $dp.Value) {
    foreach ($n in @($dp.Value)) { $script:DisabledServices[[string]$n] = $true }
}
$sp = $config.PSObject.Properties['Smtp']
if ($sp -and $sp.Value) {
    foreach ($k in @($script:SmtpConfig.Keys)) {
        $p = $sp.Value.PSObject.Properties[$k]
        if ($p -and $null -ne $p.Value) { $script:SmtpConfig[$k] = $p.Value }
    }
}
$dv = $config.PSObject.Properties['Devices']
if ($dv -and $dv.Value) {
    foreach ($d in @($dv.Value)) {
        $dn = [string]$d.Name
        if ($dn -notmatch '^[A-Za-z0-9._-]+$') { continue }
        $li = ''; $ls = ''
        if ($d.PSObject.Properties['LastKnownIP'] -and $d.LastKnownIP) { $li = [string]$d.LastKnownIP }
        if ($d.PSObject.Properties['LastSeen'] -and $d.LastSeen)       { $ls = [string]$d.LastSeen }
        $script:Devices.Add((New-DeviceObject $dn $li $ls))
    }
}
$up = $config.PSObject.Properties['Update']
if ($up -and $up.Value) {
    foreach ($k in @($script:UpdateConfig.Keys)) {
        $p = $up.Value.PSObject.Properties[$k]
        if ($p -and $null -ne $p.Value) { $script:UpdateConfig[$k] = $p.Value }
    }
}
$aa = $config.PSObject.Properties['AutoAddDiscovered']
if ($aa -and $null -ne $aa.Value) { $script:AutoAddDiscovered = [bool]$aa.Value }
$ig = $config.PSObject.Properties['IgnoredHosts']
if ($ig -and $ig.Value) {
    foreach ($x in @($ig.Value)) { $script:IgnoredHosts[[string]$x] = $true }
}
$sq = $config.PSObject.Properties['SqlServer']
if ($sq -and $sq.Value) { $script:GuruSqlServer = [string]$sq.Value }
$sn = $config.PSObject.Properties['Snapshot']
if ($sn -and $sn.Value) {
    foreach ($k in @($script:SnapshotConfig.Keys)) {
        $p = $sn.Value.PSObject.Properties[$k]
        if ($p -and $null -ne $p.Value) { $script:SnapshotConfig[$k] = [int]$p.Value }
    }
}
function New-PackageObject([string]$Name, [string]$Installer, [bool]$WholeFolder, [string]$InstArgs) {
    $copy = 'Installer only'; if ($WholeFolder) { $copy = 'Whole folder' }
    [PSCustomObject]@{ Name = $Name; Installer = $Installer; WholeFolder = $WholeFolder; Copy = $copy; Args = $InstArgs; Result = '' }
}
$swp = $config.PSObject.Properties['Software']
if ($swp -and $swp.Value) {
    $r = $swp.Value.PSObject.Properties['StationRoot']
    if ($r -and $r.Value -and ([string]$r.Value -match '^[A-Za-z]:\\')) { $script:SoftwareConfig['StationRoot'] = [string]$r.Value }
    $pk = $swp.Value.PSObject.Properties['Packages']
    if ($pk -and $pk.Value) {
        foreach ($x in @($pk.Value)) {
            if (-not $x -or -not $x.Name -or -not $x.Installer) { continue }
            $a = ''; if ($x.PSObject.Properties['Args'] -and $x.Args) { $a = [string]$x.Args }
            $w = $true; if ($x.PSObject.Properties['WholeFolder']) { $w = [bool]$x.WholeFolder }
            $script:Packages.Add((New-PackageObject ([string]$x.Name) ([string]$x.Installer) $w $a))
        }
    }
}
$ds = $config.PSObject.Properties['DeviceSeconds']
if ($ds -and $ds.Value) { $v = [int]$ds.Value; if ($v -ge 30 -and $v -le 3600) { $script:DeviceSecs = $v } }
$script:DeviceCountdown = $script:DeviceSecs
$script:RefreshSecs   = $secs
$script:CountdownSecs = $secs
$txtCountdown.Text    = Format-Countdown $secs
# ------------------------------------------------------------
# ADMIN BADGES
# ------------------------------------------------------------
if ($script:IsAdmin) {
    $adminBadge.Visibility    = [System.Windows.Visibility]::Collapsed   # always admin (script self-elevates); space used by the DB badge
    $nonAdminBadge.Visibility = [System.Windows.Visibility]::Collapsed
} else {
    $adminBadge.Visibility    = [System.Windows.Visibility]::Collapsed
    $nonAdminBadge.Visibility = [System.Windows.Visibility]::Visible
}
$btnStartAll.IsEnabled   = $script:IsAdmin
$btnStopAll.IsEnabled    = $script:IsAdmin
$btnRestartAll.IsEnabled = $script:IsAdmin
# ------------------------------------------------------------
# SYSTEM TRAY SETUP
# ------------------------------------------------------------
$script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayIcon.Icon    = [System.Drawing.SystemIcons]::Application
$script:TrayIcon.Visible = $true
$script:TrayIcon.Text    = "EMBED Services Dashboard $($script:AppVersion)"
$ctxMenu   = New-Object System.Windows.Forms.ContextMenuStrip
$miShow    = $ctxMenu.Items.Add('Show Dashboard')
$ctxMenu.Items.Add('-') | Out-Null
$miRefresh = $ctxMenu.Items.Add('Refresh Now')
$ctxMenu.Items.Add('-') | Out-Null
$miExit    = $ctxMenu.Items.Add('Exit')
$miShow.Add_Click({
    $window.Show()
    $window.WindowState = [Windows.WindowState]::Normal
    $window.Activate()
})
$miRefresh.Add_Click({
    $script:CountdownSecs = $script:RefreshSecs
    Set-StatusColor 'Updating'
    Set-TrayIconColor 'Updating'
    $statusBar.Text = "Tray refresh..."
    Update-AllServices
})
$miExit.Add_Click({
    $script:TrayIcon.Visible = $false
    $script:TrayIcon.Dispose()
    if ($script:TrayHIcon -ne [IntPtr]::Zero) { [void][Win32.NativeIcon]::DestroyIcon($script:TrayHIcon) }
    $script:Timer.Stop()
    [System.Windows.Application]::Current.Shutdown()
})
$script:TrayIcon.ContextMenuStrip = $ctxMenu
$script:TrayIcon.Add_DoubleClick({
    $window.Show()
    $window.WindowState = 'Normal'
    $window.Activate()
})
$window.Add_Closing({
    $_.Cancel = $true
    $window.Hide()
})
# ------------------------------------------------------------
# BUTTON WIRES
# ------------------------------------------------------------
$btnRefresh.Add_Click({
    $script:CountdownSecs = $script:RefreshSecs
    Set-StatusColor 'Updating'
    Set-TrayIconColor 'Updating'
    $statusBar.Text = "Manual refresh..."
    Update-AllServices
    Start-DbVersionCheck
    Start-SqlCheck
    if ($script:LastReaderLoad -ne [datetime]::MinValue) { Start-ReaderLoad }
})
$btnClearHistory.Add_Click({
    $script:HistoryList.Clear()
    $statEvents.Text = '0'
})
$btnFilterAll.Add_Click({ Apply-Filter 'All' })
$btnFilterApi.Add_Click({ Apply-Filter 'API' })
$btnFilterCore.Add_Click({ Apply-Filter 'Core' })
$btnFilterSQL.Add_Click({ Apply-Filter 'SQL' })
$btnFilterRemote.Add_Click({ Apply-Filter 'Remote' })
# Event Drill-Down 
$EventsGrid.Add_MouseDoubleClick({
    try {
        $selected = $EventsGrid.SelectedItem
        if (-not $selected) {
            return
        }
        $dialog = New-Object Windows.Window
        $dialog.Owner = $window
        $dialog.Title = "Event Details"
        $dialog.Width = 900
        $dialog.Height = 650
        $dialog.WindowStartupLocation = 'CenterOwner'
        $dialog.Background = ColorBrush '#1E1E2E'
        $dialog.Foreground = ColorBrush '#CDD6F4'
        $grid = New-Object Windows.Controls.Grid
        $row1 = New-Object Windows.Controls.RowDefinition
        $row2 = New-Object Windows.Controls.RowDefinition
        $row2.Height =
            New-Object Windows.GridLength(50)
        $grid.RowDefinitions.Add($row1)
        $grid.RowDefinitions.Add($row2)
        $txt = New-Object Windows.Controls.TextBox
        $txt.IsReadOnly = $true
        $txt.AcceptsReturn = $true
        $txt.TextWrapping = 'Wrap'
        $txt.VerticalScrollBarVisibility = 'Auto'
        $txt.Background = ColorBrush '#181825'
        $txt.Foreground = ColorBrush '#CDD6F4'
        $txt.BorderBrush = ColorBrush '#45475A'
        $txt.Margin = '10'
        $txt.Text = @"
Time:
$($selected.Time)
Level:
$($selected.Level)
Event ID:
$($selected.EventId)
Source:
$($selected.Source)
Service:
$($selected.Service)
------------------------------------------------------------
$($selected.FullMessage)
"@
        [Windows.Controls.Grid]::SetRow($txt,0)
        $btnClose = New-Object Windows.Controls.Button
        $btnClose.Content = 'Close'
        $btnClose.Width = 100
        $btnClose.HorizontalAlignment = 'Right'
        $btnClose.Margin = '10'
        $btnClose.Add_Click({
            $dialog.Close()
        })
        [Windows.Controls.Grid]::SetRow($btnClose,1)
        $grid.Children.Add($txt)      | Out-Null
        $grid.Children.Add($btnClose) | Out-Null
        $dialog.Content = $grid
        $dialog.ShowDialog() | Out-Null
    }
    catch {
        [System.Windows.MessageBox]::Show(
            $_.Exception.Message,
            'Event Viewer'
        )
    }
})
# EMBED services in start order (skipped / monitor-only services left out)
function Get-ControllableDefs([switch]$Reverse) {
    $defs   = @($script:ServiceDefs | Where-Object { -not (Test-Skipped $_.Name) -and -not $_['MonitorOnly'] })
    $sorted = @($defs | Sort-Object { $i = [array]::IndexOf($script:StartOrder, $_.Name); if ($i -lt 0) { 999 } else { $i } })
    if ($Reverse) { [array]::Reverse($sorted) }
    return $sorted
}
function Invoke-BulkAction([string]$Action) {
    if (-not $script:IsAdmin) { return }
    $statusBar.Text = "$Action All in progress..."
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    if ($Action -eq 'Stop' -or $Action -eq 'Restart') {
        foreach ($d in @(Get-ControllableDefs -Reverse)) {
            Add-HistoryEntry -ServiceName $d.Display -Group $d.Group -OldStatus '' -NewStatus "$Action All: stop" -Note (Stop-ServiceSafe $d.Name)
        }
    }
    if ($Action -eq 'Start' -or $Action -eq 'Restart') {
        foreach ($d in @(Get-ControllableDefs)) {
            Add-HistoryEntry -ServiceName $d.Display -Group $d.Group -OldStatus '' -NewStatus "$Action All: start" -Note (Start-ServiceSafe $d.Name)
        }
    }
    Update-AllServices
}
$btnStartAll.Add_Click({   Invoke-BulkAction 'Start' })
$btnStopAll.Add_Click({    Invoke-BulkAction 'Stop' })
$btnRestartAll.Add_Click({ Invoke-BulkAction 'Restart' })
# ------------------------------------------------------------
# ALERTS (SMTP) WIRING
# ------------------------------------------------------------
function Set-SmtpStatus([string]$text, [string]$hex) {
    $txtSmtpStatus.Text       = $text
    $txtSmtpStatus.Foreground = ColorBrush $hex
}
function Update-SmtpPwdHint {
    $txtPwdHint.Text = if ([string]$script:SmtpConfig['PasswordEnc']) { 'Saved - leave blank to keep' } else { '' }
}
function Initialize-SmtpUi {
    $c = $script:SmtpConfig
    $chkSmtpEnabled.IsChecked = [bool]$c['Enabled']
    $txtSmtpServer.Text       = [string]$c['Server']
    $txtSmtpPort.Text         = [string]$c['Port']
    $chkSmtpSsl.IsChecked     = [bool]$c['UseSsl']
    $txtSmtpUser.Text         = [string]$c['Username']
    $txtSmtpFrom.Text         = [string]$c['From']
    $txtSmtpTo.Text           = [string]$c['To']
    $txtSmtpThreshold.Text    = [string]$c['Threshold']
    $txtSmtpWindow.Text       = [string]$c['WindowMinutes']
    $txtSmtpCooldown.Text     = [string]$c['CooldownMinutes']
    Update-SmtpPwdHint
}
# Validates the fields and copies them into $script:SmtpConfig. Returns $null if OK, otherwise an error message.
function Apply-SmtpUi {
    $port = 0; $thr = 0; $win = 0; $cool = 0
    if (-not [int]::TryParse($txtSmtpPort.Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) { return 'Port must be a number from 1 to 65535.' }
    if (-not [int]::TryParse($txtSmtpThreshold.Text.Trim(), [ref]$thr) -or $thr -lt 1)  { return 'Offline events must be 1 or more.' }
    if (-not [int]::TryParse($txtSmtpWindow.Text.Trim(), [ref]$win) -or $win -lt 1)     { return 'Minutes window must be 1 or more.' }
    if (-not [int]::TryParse($txtSmtpCooldown.Text.Trim(), [ref]$cool) -or $cool -lt 0) { return 'Cooldown must be 0 or more minutes.' }
    $enabled = [bool]$chkSmtpEnabled.IsChecked
    $server  = $txtSmtpServer.Text.Trim()
    $from    = $txtSmtpFrom.Text.Trim()
    $to      = $txtSmtpTo.Text.Trim()
    if ($enabled -and (-not $server -or -not $from -or -not $to)) { return 'Server, From and Send alerts to are required to enable alerts.' }
    try {
        if ($from) { [void](New-Object System.Net.Mail.MailAddress($from)) }
        foreach ($a in ($to -split '[;,]')) { if ($a.Trim()) { [void](New-Object System.Net.Mail.MailAddress($a.Trim())) } }
    } catch { return 'One of the email addresses is not valid.' }
    $c = $script:SmtpConfig
    $c['Enabled']         = $enabled
    $c['Server']          = $server
    $c['Port']            = $port
    $c['UseSsl']          = [bool]$chkSmtpSsl.IsChecked
    $c['Username']        = $txtSmtpUser.Text.Trim()
    $c['From']            = $from
    $c['To']              = $to
    $c['Threshold']       = $thr
    $c['WindowMinutes']   = $win
    $c['CooldownMinutes'] = $cool
    if (-not $c['Username']) {
        $c['PasswordEnc'] = ''
    } elseif ($pwdSmtp.Password) {
        $c['PasswordEnc'] = (ConvertTo-SecureString $pwdSmtp.Password -AsPlainText -Force | ConvertFrom-SecureString)
    }
    $pwdSmtp.Clear()
    return $null
}
$btnSmtpSave.Add_Click({
    $err = Apply-SmtpUi
    if ($err) { Set-SmtpStatus $err '#F38BA8'; return }
    Save-Config -RefreshSeconds ($script:RefreshSecs)
    Update-SmtpPwdHint
    Set-SmtpStatus ("Saved at {0}" -f (Get-Date).ToString('HH:mm:ss')) '#A6E3A1'
})
$btnSmtpTest.Add_Click({
    $err = Apply-SmtpUi
    if ($err) { Set-SmtpStatus $err '#F38BA8'; return }
    $c = $script:SmtpConfig
    if (-not $c['Server'] -or -not $c['From'] -or -not $c['To']) {
        Set-SmtpStatus 'Fill in Server, From and Send alerts to first.' '#F38BA8'
        return
    }
    Save-Config -RefreshSeconds ($script:RefreshSecs)
    Update-SmtpPwdHint
    Set-SmtpStatus 'Sending test email...' '#89B4FA'
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $body = "This is a test email from the EMBED Services Dashboard on $env:COMPUTERNAME.`r`nSent: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))`r`n`r`nIf you received this, SMTP alerts are set up correctly."
    $sendErr = Send-SmtpMessage -Subject "[EMBED] Test email from $env:COMPUTERNAME" -Body $body
    if ($sendErr) { Set-SmtpStatus "Test failed: $sendErr" '#F38BA8' }
    else          { Set-SmtpStatus ("Test email sent to {0} at {1}" -f $c['To'], (Get-Date).ToString('HH:mm:ss')) '#A6E3A1' }
})
Initialize-SmtpUi
# ------------------------------------------------------------
# SETTINGS TAB: GITHUB UPDATES
# ------------------------------------------------------------
# Background job. Reads version.json from the repo; packaged apps download a verified GitHub release asset.
$script:UpdateScript = {
    param($repo, $branch, $token, $currentVersion, $download, $isPackagedExe)
    $out = [ordered]@{ Ok = $false; Error = ''; Latest = ''; Notes = ''; Newer = $false; File = ''; Content = ''; AssetPath = '' }
    $assetPath = $null
    function Get-GitHubText([string]$Repo, [string]$Branch, [string]$Path, [string]$Token) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $h = @{ 'User-Agent' = 'EMBED-Services-Dashboard'; 'Accept' = 'application/vnd.github.raw+json' }
        if ($Token) { $h['Authorization'] = 'Bearer ' + $Token }
        if ($Token) { $h['Authorization'] = "Bearer $Token" }
        $uri = 'https://api.github.com/repos/{0}/contents/{1}?ref={2}' -f $Repo, $Path, $Branch
        if ($Token) { $h['Authorization'] = 'Bearer ' + $Token }
        $r = Invoke-WebRequest -Uri $uri -Headers $h -UseBasicParsing -TimeoutSec 20
        $c = $r.Content
        if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
        return ([string]$c).TrimStart([char]0xFEFF)
    }
    function Get-GitHubApiHeaders([string]$Token) {
        $headers = @{
            'User-Agent' = 'EMBED-Services-Dashboard'
            'Accept' = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
        if ($Token) { $headers['Authorization'] = 'Bearer ' + $Token }
        return $headers
    }
    try {
        $vj = Get-GitHubText $repo $branch 'version.json' $token | ConvertFrom-Json
        $latest = [string]$vj.version
        if ($latest -notmatch '^\d+(\.\d+){1,3}$') { throw 'version.json does not contain a valid version number.' }
        $out.Latest = $latest
        $out.Notes  = [string]$vj.notes
        $out.Newer  = ([version]$latest -gt [version]$currentVersion)
        $out.Ok     = $true
        if ($out.Newer -and $download) {
            if ($isPackagedExe) {
                $assetName = [string]$vj.exeAsset
                if ($assetName -notmatch '^[A-Za-z0-9._-]+\.exe$') {
                    throw 'version.json does not name a valid .exe release asset.'
                }
                $tag = [string]$vj.releaseTag
                if (-not $tag) { $tag = "v$latest" }
                if ($tag -notmatch '^[A-Za-z0-9._-]+$') { throw 'version.json contains an invalid release tag.' }
                $releaseUri = 'https://api.github.com/repos/{0}/releases/tags/{1}' -f $repo, [Uri]::EscapeDataString($tag)
                $release = Invoke-RestMethod -Uri $releaseUri -Headers (Get-GitHubApiHeaders $token) -TimeoutSec 30
                $asset = @($release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1)
                if ($asset.Count -eq 0) { throw "Release $tag does not include the expected executable asset $assetName." }
                $asset = $asset[0]
                $expectedHash = ([string]$vj.exeSha256).ToLower()
                if (-not $expectedHash -and [string]$asset.digest -match '^sha256:([a-fA-F0-9]{64})$') {
                    $expectedHash = $Matches[1].ToLower()
                }
                if ($expectedHash -notmatch '^[a-f0-9]{64}$') {
                    throw 'The executable update has no valid SHA-256 digest in version.json or GitHub release metadata.'
                }
                $headers = Get-GitHubApiHeaders $token
                $headers['Accept'] = 'application/octet-stream'
                $assetPath = Join-Path ([IO.Path]::GetTempPath()) ('EMBED_Dashboard_{0}.exe' -f [Guid]::NewGuid().ToString('N'))
                [void](Invoke-WebRequest -Uri ([string]$asset.browser_download_url) -Headers $headers -OutFile $assetPath -UseBasicParsing -TimeoutSec 120)
                $actualHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLower()
                if ($actualHash -ne $expectedHash) {
                    Remove-Item -LiteralPath $assetPath -Force -ErrorAction SilentlyContinue
                    throw 'The downloaded executable does not match the expected SHA-256 digest, so the update was cancelled.'
                }
                $out.File = $assetName
                $out.AssetPath = $assetPath
            } else {
                $file = [string]$vj.file
                if ($file -notmatch '^[A-Za-z0-9._-]+\.ps1$') { throw 'version.json does not name a valid .ps1 file.' }
                $content = Get-GitHubText $repo $branch $file $token
                $norm = $content -replace "`r`n", "`n"
                $sha  = [System.Security.Cryptography.SHA256]::Create()
                $hash = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($norm)) | ForEach-Object { $_.ToString('x2') }) -join '')
                if ($hash -ne ([string]$vj.sha256).ToLower()) { throw 'The downloaded file does not match the hash in version.json, so the update was cancelled.' }
                $tokens = $null; $errs = $null
                [void][System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errs)
                if ($errs -and $errs.Count -gt 0) { throw 'The downloaded file is not valid PowerShell, so the update was cancelled.' }
                $pat = '\$script:AppVersion\s*=\s*["'']' + [regex]::Escape($latest) + '["'']'
                if ($content -notmatch $pat) { throw "The downloaded file does not declare version $latest, so the update was cancelled." }
                $out.File    = $file
                $out.Content = $content
            }
        }
    } catch {
        if ($assetPath) { Remove-Item -LiteralPath $assetPath -Force -ErrorAction SilentlyContinue }
        $out.Ok = $false
        $msg  = $_.Exception.Message
        $resp = $_.Exception.Response
        if ($resp) {
            $code = [int]$resp.StatusCode
            if ($code -eq 404) { $msg = 'GitHub could not find the update metadata, release, or asset. Check the repository, branch, version.json, and release tag.' }
            elseif ($code -eq 401 -or $code -eq 403) { $msg = 'GitHub refused access. Check the token (private repositories), or the rate limit was reached - try again later.' }
        }
        $out.Error = $msg
    }
    [PSCustomObject]$out
}
function Set-UpdateStatus([string]$text, [string]$hex) {
    $txtUpdStatus.Text       = $text
    $txtUpdStatus.Foreground = ColorBrush $hex
}
function Get-UpdateToken {
    $enc = [string]$script:UpdateConfig['TokenEnc']
    if (-not $enc) { return '' }
    try { return (New-Object System.Net.NetworkCredential('', (ConvertTo-SecureString $enc))).Password } catch { return '' }
}
function Initialize-UpdateUi {
    $c = $script:UpdateConfig
    $txtUpdVersion.Text      = "Installed version: $($script:AppVersion)"
    $txtUpdRepo.Text         = [string]$c['Repo']
    $txtUpdBranch.Text       = [string]$c['Branch']
    $chkUpdAuto.IsChecked    = [bool]$c['AutoCheck']
    $chkUpdInstall.IsChecked = [bool]$c['AutoInstall']
    $txtUpdTokenHint.Text    = ''
    if ([string]$c['TokenEnc']) { $txtUpdTokenHint.Text = 'Saved - leave blank to keep' }
}
# Validates the fields and copies them into $script:UpdateConfig. Returns $null if OK, otherwise an error message.
function Apply-UpdateUi {
    $repo = $txtUpdRepo.Text.Trim()
    $repo = $repo -replace '^https?://github\.com/', '' -replace '\.git$', '' -replace '/+$', ''
    $branch = $txtUpdBranch.Text.Trim()
    if (-not $branch) { $branch = 'main' }
    if ($repo -and $repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { return 'The repository must look like owner/name, for example mycompany/embed-dashboard.' }
    if ($branch -notmatch '^[A-Za-z0-9_./-]+$') { return 'The branch name has characters that are not allowed.' }
    $c = $script:UpdateConfig
    $c['Repo']        = $repo
    $c['Branch']      = $branch
    $c['AutoCheck']   = [bool]$chkUpdAuto.IsChecked
    $c['AutoInstall'] = [bool]$chkUpdInstall.IsChecked
    if ($pwdUpdToken.Password) {
        $c['TokenEnc'] = (ConvertTo-SecureString $pwdUpdToken.Password -AsPlainText -Force | ConvertFrom-SecureString)
    }
    $pwdUpdToken.Clear()
    return $null
}
function Start-UpdateCheck([bool]$Download) {
    if ($script:UpdateScan) { return }
    $c = $script:UpdateConfig
    if (-not [string]$c['Repo']) { return }
    $script:LastUpdateCheck = Get-Date
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:UpdateScript.ToString()).AddArgument([string]$c['Repo']).AddArgument([string]$c['Branch']).AddArgument((Get-UpdateToken)).AddArgument([string]$script:AppVersion).AddArgument($Download).AddArgument([bool]$script:IsPackagedExe)
        $script:UpdateScan = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
        $btnUpdCheck.IsEnabled = $false
    } catch {
        $script:UpdateScan = $null
        $btnUpdCheck.IsEnabled = $true
        Set-UpdateStatus "Could not start the update check: $($_.Exception.Message)" '#F38BA8'
    }
}
function Install-UpdateContent([string]$Content, [string]$NewVersion) {
    $path = [string]$script:SelfPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        Set-UpdateStatus 'Updates need the dashboard to be run from a saved .ps1 file.' '#F38BA8'
        return
    }
    try {
        $dir = Split-Path $path -Parent
        $bk  = Join-Path $dir 'Backups'
        if (-not (Test-Path -LiteralPath $bk)) { [void](New-Item -ItemType Directory -Path $bk) }
        $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $bkName = '{0}_v{1}_{2}.bak' -f [IO.Path]::GetFileNameWithoutExtension($path), $script:AppVersion, $stamp
        Copy-Item -LiteralPath $path -Destination (Join-Path $bk $bkName)
        Get-ChildItem -LiteralPath $bk -Filter '*.bak' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 | Remove-Item -Force
        $text = ($Content -replace "`r`n", "`n") -replace "`n", "`r`n"
        $tmp  = "$path.new"
        [IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($true)))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch {
        Set-UpdateStatus "Update failed: $($_.Exception.Message)" '#F38BA8'
        return
    }
    Set-UpdateStatus "Updated to v$NewVersion - restarting..." '#A6E3A1'
    try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch {}
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$path`""
    [Environment]::Exit(0)
}
function Install-ExecutableUpdate([string]$AssetPath, [string]$NewVersion) {
    $path = [string]$script:SelfPath
    if (-not $script:IsPackagedExe -or -not $path -or -not (Test-Path -LiteralPath $path)) {
        Set-UpdateStatus 'Executable updates are only available when running the packaged dashboard EXE.' '#F38BA8'
        return
    }
    $stagedPath = "$path.update"
    $helperPath = $null
    try {
        $backupDir = Join-Path (Split-Path $path -Parent) 'Backups'
        if (-not (Test-Path -LiteralPath $backupDir)) { [void](New-Item -ItemType Directory -Path $backupDir) }
        $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $backupPath = Join-Path $backupDir ('{0}_v{1}_{2}.exe' -f [IO.Path]::GetFileNameWithoutExtension($path), $script:AppVersion, $stamp)
        Copy-Item -LiteralPath $AssetPath -Destination $stagedPath -Force

        $helperPath = Join-Path ([IO.Path]::GetTempPath()) ('EMBED_Dashboard_Update_{0}.ps1' -f [Guid]::NewGuid().ToString('N'))
        $helper = @'
param([int]$ParentProcessId, [string]$TargetPath, [string]$StagedPath, [string]$BackupPath, [string]$LogPath, [string]$DownloadedPath)
$ErrorActionPreference = 'Stop'
try {
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
    if (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue) { throw 'The dashboard did not exit in time.' }
    Copy-Item -LiteralPath $TargetPath -Destination $BackupPath -Force
    try {
        Move-Item -LiteralPath $StagedPath -Destination $TargetPath -Force
        Start-Process -FilePath $TargetPath
    } catch {
        Copy-Item -LiteralPath $BackupPath -Destination $TargetPath -Force
        throw
    }
} catch {
    try { [IO.File]::WriteAllText($LogPath, $_.Exception.Message) } catch {}
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [Windows.Forms.MessageBox]::Show("Dashboard update failed: $($_.Exception.Message)`r`nThe previous executable was restored when possible.", 'Dashboard update', 'OK', 'Error') | Out-Null
    } catch {}
} finally {
    Remove-Item -LiteralPath $StagedPath, $DownloadedPath, $PSCommandPath -Force -ErrorAction SilentlyContinue
}
'@
        [IO.File]::WriteAllText($helperPath, $helper, (New-Object System.Text.UTF8Encoding($true)))
        $logPath = "$helperPath.log"
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1} "{2}" "{3}" "{4}" "{5}" "{6}"' -f $helperPath, $PID, $path, $stagedPath, $backupPath, $logPath, $AssetPath
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden
    } catch {
        Remove-Item -LiteralPath $stagedPath, $AssetPath -Force -ErrorAction SilentlyContinue
        if ($helperPath) { Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue }
        Set-UpdateStatus "Could not stage executable update: $($_.Exception.Message)" '#F38BA8'
        return
    }
    Set-UpdateStatus "Installing v$NewVersion and restarting..." '#A6E3A1'
    try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch {}
    [Environment]::Exit(0)
}
function Complete-UpdateCheck {
    $scan = $script:UpdateScan
    $script:UpdateScan = $null
    $btnUpdCheck.IsEnabled = $true
    $res = $null
    try { $res = @($scan.PS.EndInvoke($scan.Handle)) | Select-Object -First 1 }
    catch { Set-UpdateStatus "Update check failed: $($_.Exception.Message)" '#F38BA8'; return }
    finally { try { $scan.PS.Dispose(); $scan.RS.Close(); $scan.RS.Dispose() } catch {} }
    if (-not $res) { Set-UpdateStatus 'The update check returned nothing.' '#F38BA8'; return }
    if (-not $res.Ok) {
        if ($res.Newer) { $btnUpdInstall.Visibility = 'Visible' }
        Set-UpdateStatus "Update check failed: $($res.Error)" '#F38BA8'
        return
    }
    if (-not $res.Newer) {
        $btnUpdInstall.Visibility = 'Collapsed'
        $script:UpdateInfo = $null
        Set-UpdateStatus ("You are up to date (v{0}). Last checked {1}." -f $script:AppVersion, (Get-Date).ToString('HH:mm:ss')) '#A6E3A1'
        return
    }
    $script:UpdateInfo = $res
    $btnUpdInstall.Visibility = 'Visible'
    $note = ''
    if ($res.Notes) { $note = " - $($res.Notes)" }
    Set-UpdateStatus "Update available: v$($res.Latest)$note" '#F9E2AF'
    if ($res.Content) {
        Install-UpdateContent ([string]$res.Content) ([string]$res.Latest)
    } elseif ($res.AssetPath) {
        Install-ExecutableUpdate ([string]$res.AssetPath) ([string]$res.Latest)
    } elseif ($script:UpdateNotified -ne [string]$res.Latest) {
        $script:UpdateNotified = [string]$res.Latest
        try { $script:TrayIcon.ShowBalloonTip(6000, "EMBED Services Dashboard $($script:AppVersion)", "Update v$($res.Latest) is available (Settings tab).", [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
    }
}
$btnUpdSave.Add_Click({
    $err = Apply-UpdateUi
    if ($err) { Set-UpdateStatus $err '#F38BA8'; return }
    Save-AllConfig
    Initialize-UpdateUi
    Set-UpdateStatus ("Saved at {0}" -f (Get-Date).ToString('HH:mm:ss')) '#A6E3A1'
})
$btnUpdCheck.Add_Click({
    $err = Apply-UpdateUi
    if ($err) { Set-UpdateStatus $err '#F38BA8'; return }
    Save-AllConfig
    Initialize-UpdateUi
    if (-not [string]$script:UpdateConfig['Repo']) { Set-UpdateStatus 'Enter the GitHub repository first.' '#F38BA8'; return }
    if ($script:UpdateScan) { Set-UpdateStatus 'A check is already running...' '#89B4FA'; return }
    Set-UpdateStatus 'Checking GitHub...' '#89B4FA'
    Start-UpdateCheck $false
})
$btnUpdInstall.Add_Click({
    $info = $script:UpdateInfo
    if (-not $info) { return }
    $ans = [System.Windows.MessageBox]::Show("Install version $($info.Latest) now?`r`nThe dashboard will restart, and the current version is backed up first.", 'Install update', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    Set-UpdateStatus 'Downloading and checking the update...' '#89B4FA'
    Start-UpdateCheck $true
})
$chkDscAuto.Add_Click({
    $script:AutoAddDiscovered = [bool]$chkDscAuto.IsChecked
    Save-AllConfig
})
$chkDscAuto.IsChecked = [bool]$script:AutoAddDiscovered
Initialize-UpdateUi
# ------------------------------------------------------------
# SUPPORT SNAPSHOT
# ------------------------------------------------------------
$script:SnapshotScript = {
    param($workDir, $zipPath, $sqlServer, $ecsDir, $dataRoot, $svcNames)
    $ErrorActionPreference = 'Stop'
    function Get-Deepest($err) { $e = $err.Exception; while ($e.InnerException) { $e = $e.InnerException }; $e.Message }
    function Save-Section([string]$File, [scriptblock]$Block) {
        $path = Join-Path $workDir $File
        try   { & $Block | Out-File -FilePath $path -Encoding UTF8 -Width 400 }
        catch { "Could not collect this section: $(Get-Deepest $_)" | Out-File -FilePath $path -Encoding UTF8 }
    }
    function Invoke-SqlRows([string]$Sql) {
        $cn = New-Object System.Data.SqlClient.SqlConnection "Server=$sqlServer;Database=master;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=5"
        try {
            $cn.Open()
            $cmd = $cn.CreateCommand(); $cmd.CommandText = $Sql; $cmd.CommandTimeout = 20
            $dt = New-Object System.Data.DataTable
            $dt.Load($cmd.ExecuteReader())
            foreach ($r in $dt.Rows) {
                $o = [ordered]@{}
                foreach ($c in $dt.Columns) { $o[$c.ColumnName] = $r[$c] }
                [PSCustomObject]$o
            }
        } finally { $cn.Dispose() }
    }

    Save-Section '02_Service_Details.txt' {
        Get-CimInstance Win32_Service | Where-Object { $svcNames -contains $_.Name } |
            Select-Object Name, DisplayName, State, StartMode, StartName, ExitCode, ProcessId, PathName | Format-List
    }
    Save-Section '03_System.txt' {
        $os  = Get-CimInstance Win32_OperatingSystem
        $cs  = Get-CimInstance Win32_ComputerSystem
        $cpu = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
        $up  = (Get-Date) - $os.LastBootUpTime
        $reboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                  (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        $ts = 'unknown'
        try { $ts = (& w32tm /query /source 2>&1 | Out-String).Trim() } catch {}
        [PSCustomObject]@{
            Computer      = $env:COMPUTERNAME
            Domain        = $cs.Domain
            OS            = "$($os.Caption) (build $($os.BuildNumber))"
            LastBoot      = $os.LastBootUpTime
            Uptime        = '{0}d {1}h {2}m' -f $up.Days, $up.Hours, $up.Minutes
            CpuLoadPct    = $cpu
            RamUsedPct    = [math]::Round((1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) * 100, 1)
            PendingReboot = $reboot
            TimeSource    = $ts
            LocalTime     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
        } | Format-List
        Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
            Select-Object DeviceID,
                @{n='SizeGB';e={ [math]::Round($_.Size / 1GB, 1) }},
                @{n='FreeGB';e={ [math]::Round($_.FreeSpace / 1GB, 1) }},
                @{n='FreePct';e={ if ($_.Size) { [math]::Round($_.FreeSpace / $_.Size * 100, 1) } else { 0 } }} |
            Format-Table -AutoSize
    }
    Save-Section '04_Event_Errors_24h.txt' {
        try {
            Get-WinEvent -FilterHashtable @{ LogName = 'Application','System'; Level = 1,2; StartTime = (Get-Date).AddHours(-24) } -MaxEvents 300 |
                Select-Object TimeCreated, LogName, ProviderName, Id, @{n='Message';e={ ([string]$_.Message -replace '\s+', ' ') }} | Format-List
        } catch {
            if ((Get-Deepest $_) -like '*No events were found*') { 'No errors or critical events in the last 24 hours.' } else { throw }
        }
    }
    Save-Section '05_EMBED_SQL_Events_7d.txt' {
        $rx = (@($svcNames | ForEach-Object { [regex]::Escape($_) }) + 'EMBED', 'ECS', 'MSSQL') -join '|'
        try {
            $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application','System'; Level = 1,2,3; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 5000 |
                Where-Object { $_.ProviderName -match $rx -or ($_.ProviderName -eq 'Service Control Manager' -and [string]$_.Message -match $rx) })
            if ($ev.Count -eq 0) { 'No EMBED / SQL related warnings or errors in the last 7 days.' }
            else { $ev | Select-Object TimeCreated, LevelDisplayName, ProviderName, Id, @{n='Message';e={ ([string]$_.Message -replace '\s+', ' ') }} | Format-List }
        } catch {
            if ((Get-Deepest $_) -like '*No events were found*') { 'No warnings or errors in the last 7 days.' } else { throw }
        }
    }
    Save-Section '06_SQL.txt' {
        "SQL Server: $sqlServer"; ''
        '=== Version ==='
        Invoke-SqlRows "SELECT @@SERVERNAME AS ServerName, SERVERPROPERTY('Edition') AS Edition, SERVERPROPERTY('ProductVersion') AS Version, SERVERPROPERTY('ProductLevel') AS Level" | Format-List
        '=== Database file sizes (MB)  - Express edition data files max out at 10 GB ==='
        Invoke-SqlRows "SELECT DB_NAME(database_id) AS DbName, type_desc AS FileType, CAST(SUM(CAST(size AS bigint)) * 8 / 1024.0 AS decimal(12,1)) AS SizeMB FROM sys.master_files GROUP BY database_id, type_desc ORDER BY DbName, FileType" | Format-Table -AutoSize
        '=== Last full backup ==='
        Invoke-SqlRows "SELECT d.name AS DbName, d.recovery_model_desc AS Recovery, MAX(b.backup_finish_date) AS LastFullBackup FROM sys.databases d LEFT JOIN msdb.dbo.backupset b ON b.database_name = d.name AND b.type = 'D' GROUP BY d.name, d.recovery_model_desc ORDER BY d.name" | Format-Table -AutoSize
        '=== Blocked sessions right now ==='
        $blk = @(Invoke-SqlRows "SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time AS WaitMs, DB_NAME(r.database_id) AS DbName, r.command FROM sys.dm_exec_requests r WHERE r.blocking_session_id <> 0")
        if ($blk.Count -eq 0) { 'None' } else { $blk | Format-Table -AutoSize }
    }
    Save-Section '07_Listening_Ports.txt' {
        $procs = @{}; foreach ($p in Get-Process) { $procs[$p.Id] = $p.ProcessName }
        Get-NetTCPConnection -State Listen | Sort-Object LocalPort -Unique |
            Select-Object LocalAddress, LocalPort, OwningProcess, @{n='Process';e={ $procs[[int]$_.OwningProcess] }} | Format-Table -AutoSize
    }
    Save-Section '08_EMBED_Versions.txt' {
        "Folder: $ecsDir"
        Get-ChildItem -LiteralPath $ecsDir -File | Where-Object { $_.Extension -in '.exe', '.dll' } |
            Select-Object Name, @{n='FileVersion';e={ $_.VersionInfo.FileVersion }}, LastWriteTime | Sort-Object Name | Format-Table -AutoSize
    }
    # Tail of the most recently written EMBED log files (last 48 h)
    try {
        $logOut = Join-Path $workDir 'Logs'
        New-Item -ItemType Directory -Path $logOut -Force | Out-Null
        $cut = (Get-Date).AddHours(-48)
        $recent = @(Get-ChildItem -Path (Join-Path $ecsDir '*') -Recurse -File -Include *.log, *.txt -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $cut -and $_.FullName -notlike "$dataRoot*" } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 8)
        foreach ($f in $recent) {
            $dest = Join-Path $logOut ('{0}__{1}' -f $f.Directory.Name, $f.Name)
            try   { Get-Content -LiteralPath $f.FullName -Tail 3000 | Out-File -FilePath $dest -Encoding UTF8 -Width 1000 }
            catch { "Could not read $($f.FullName): $(Get-Deepest $_)" | Out-File -FilePath $dest -Encoding UTF8 }
        }
        if ($recent.Count -eq 0) { "No .log/.txt files changed in the last 48 hours under $ecsDir" | Out-File (Join-Path $logOut 'none.txt') -Encoding UTF8 }
    } catch { "Log copy failed: $(Get-Deepest $_)" | Out-File (Join-Path $workDir 'Logs_error.txt') -Encoding UTF8 }

    Compress-Archive -Path (Join-Path $workDir '*') -DestinationPath $zipPath -Force
    Remove-Item -LiteralPath $workDir -Recurse -Force
    $zipPath
}
# Keeps the newest KeepCount snapshots, deletes anything older than MaxAgeDays (0 = no age limit). Returns how many were deleted.
function Remove-OldSnapshots {
    if (-not (Test-Path -LiteralPath $script:SnapshotRoot)) { return 0 }
    $keep = [int]$script:SnapshotConfig['KeepCount']
    $days = [int]$script:SnapshotConfig['MaxAgeDays']
    $cutoff  = (Get-Date).AddDays(-$days)
    $removed = 0
    $all = @(Get-ChildItem -LiteralPath $script:SnapshotRoot -Filter 'Snapshot_*.zip' | Sort-Object LastWriteTime -Descending)
    for ($i = 0; $i -lt $all.Count; $i++) {
        if ($i -ge $keep -or ($days -gt 0 -and $all[$i].LastWriteTime -lt $cutoff)) {
            try { Remove-Item -LiteralPath $all[$i].FullName -Force; $removed++ } catch {}
        }
    }
    # leftovers from a snapshot that crashed half-way
    Get-ChildItem -LiteralPath $script:SnapshotRoot -Directory -Filter 'work_*' |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    return $removed
}
function Remove-OldHistoryLogs {
    if (-not (Test-Path -LiteralPath $script:HistoryDir)) { return }
    $cut = (Get-Date).AddDays(-$script:HistoryDays)
    Get-ChildItem -LiteralPath $script:HistoryDir -Filter 'History_*.csv' |
        Where-Object { $_.LastWriteTime -lt $cut } | Remove-Item -Force -ErrorAction SilentlyContinue
}
function Start-Snapshot {
    if ($script:SnapshotJob) { $statusBar.Text = 'A snapshot is already being built...'; return }
    try {
        $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
        if (-not (Test-Path -LiteralPath $script:SnapshotRoot)) { New-Item -ItemType Directory -Path $script:SnapshotRoot -Force | Out-Null }
        $work = Join-Path $script:SnapshotRoot "work_$stamp"
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $zip = Join-Path $script:SnapshotRoot ('Snapshot_{0}_{1}.zip' -f $env:COMPUTERNAME, $stamp)

        # What the dashboard sees right now (quick, done here)
        $svc = foreach ($d in $script:ServiceDefs) {
            $st = $script:ServiceCache[$d.Name]
            if (-not $st) { $st = Get-SafeServiceStatus $d.Name }
            $mon = 'On'
            if ($script:DisabledServices.ContainsKey($d.Name)) { $mon = 'Off (user)' }
            elseif ($script:AutoOff.ContainsKey($d.Name))      { $mon = 'Off (not installed)' }
            [PSCustomObject]@{ Service = $d.Display; Name = $d.Name; Group = $d.Group; Status = $st.Status; StartType = $st.StartType; Monitoring = $mon; Error = $st.Error }
        }
        $svc | Export-Csv (Join-Path $work '01_Services.csv') -NoTypeInformation -Encoding UTF8
        @($script:HistoryList) | Export-Csv (Join-Path $work '09_History_ThisSession.csv') -NoTypeInformation -Encoding UTF8
        @($script:Devices) | Select-Object Name, Status, CurrentIP, LastKnownIP, LastSeen, Detail |
            Export-Csv (Join-Path $work '10_Devices.csv') -NoTypeInformation -Encoding UTF8
        @(
            "EMBED Services Dashboard support snapshot",
            "Dashboard version: $($script:AppVersion)",
            "Server:            $env:COMPUTERNAME",
            "Created:           $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))",
            "Created by:        $env:USERDOMAIN\$env:USERNAME",
            "",
            (Get-DbVersionText)
        ) | Set-Content (Join-Path $work '00_README.txt') -Encoding UTF8

        # The slow parts run in the background so the window doesn't freeze
        $names = [string[]]@($script:ServiceDefs | ForEach-Object { $_.Name })
        $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($script:SnapshotScript.ToString()).AddArgument($work).AddArgument($zip).AddArgument($script:GuruSqlServer).AddArgument($script:EcsDir).AddArgument($script:DataRoot).AddArgument($names)
        $script:SnapshotJob = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
        $btnSnapshot.IsEnabled = $false
        $statusBar.Text = 'Building support snapshot (about 10-30 seconds)...'
    } catch {
        $script:SnapshotJob = $null
        $btnSnapshot.IsEnabled = $true
        $statusBar.Text = "Snapshot failed: $($_.Exception.Message)"
    }
}
function Complete-Snapshot {
    $job = $script:SnapshotJob
    $script:SnapshotJob = $null
    $btnSnapshot.IsEnabled = $true
    $zip = $null
    try     { $zip = @($job.PS.EndInvoke($job.Handle)) | Select-Object -Last 1 }
    catch   { $statusBar.Text = "Snapshot failed: $($_.Exception.Message)"; return }
    finally { try { $job.PS.Dispose(); $job.RS.Close(); $job.RS.Dispose() } catch {} }
    if (-not $zip -or -not (Test-Path -LiteralPath ([string]$zip))) { $statusBar.Text = 'Snapshot failed: no zip was created.'; return }
    $removed = Remove-OldSnapshots
    try { [System.Windows.Clipboard]::SetText([string]$zip) } catch {}
    Start-Process explorer.exe -ArgumentList "/select,`"$zip`""
    $statusBar.Text = "Snapshot saved (path copied to clipboard). $removed old snapshot(s) removed."
}
function Set-SnapStatus([string]$text, [string]$hex) { $txtSnapStatus.Text = $text; $txtSnapStatus.Foreground = ColorBrush $hex }
function Initialize-SnapshotUi {
    $txtSnapKeep.Text  = [string]$script:SnapshotConfig['KeepCount']
    $txtSnapDays.Text  = [string]$script:SnapshotConfig['MaxAgeDays']
    $txtSqlServer.Text = [string]$script:GuruSqlServer
}
$btnSnapshot.Add_Click({ Start-Snapshot })
$btnSnapSave.Add_Click({
    $k = 0; $dd = 0
    if (-not [int]::TryParse($txtSnapKeep.Text.Trim(), [ref]$k) -or $k -lt 1 -or $k -gt 100)  { Set-SnapStatus 'Keep must be a number from 1 to 100.' '#F38BA8'; return }
    if (-not [int]::TryParse($txtSnapDays.Text.Trim(), [ref]$dd) -or $dd -lt 0 -or $dd -gt 365) { Set-SnapStatus 'Days must be a number from 0 to 365.' '#F38BA8'; return }
    $sql = $txtSqlServer.Text.Trim()
    if (-not $sql) { $sql = 'localhost' }
    if ($sql -notmatch '^[A-Za-z0-9._\\,-]+$') { Set-SnapStatus 'SQL Server name has characters that are not allowed.' '#F38BA8'; return }
    $script:SnapshotConfig['KeepCount']  = $k
    $script:SnapshotConfig['MaxAgeDays'] = $dd
    $script:GuruSqlServer = $sql
    Save-AllConfig
    $n = Remove-OldSnapshots
    Start-DbVersionCheck
    Set-SnapStatus ("Saved at {0}. {1} old snapshot(s) removed." -f (Get-Date).ToString('HH:mm:ss'), $n) '#A6E3A1'
})
$btnSnapOpen.Add_Click({
    if (-not (Test-Path -LiteralPath $script:SnapshotRoot)) { New-Item -ItemType Directory -Path $script:SnapshotRoot -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList "`"$($script:SnapshotRoot)`""
})
# ------------------------------------------------------------
# REMOTE SERVICES (control EMBED services on another PC)
# ------------------------------------------------------------
$dgRemote.ItemsSource = $script:RemoteList
# Background job: optional Stop/Start/Restart of $targets (in order; stop runs in reverse), then reads the requested remote services.
$script:RemoteSvcScript = {
    param($computer, $action, $targets, $queryNames)
    Add-Type -AssemblyName System.ServiceProcess
    $timeout = [TimeSpan]::FromSeconds(60)
    $log = @()
    function Get-Deepest($err) { $e = $err.Exception; while ($e.InnerException) { $e = $e.InnerException }; return $e }
    function New-Log($n, $result, $note) { [PSCustomObject]@{ Name = $n; Result = $result; Note = $note } }

    # Quick reachability check so a dead PC fails in seconds instead of hanging on RPC timeouts
    $reach = $false
    foreach ($port in 445, 135) {
        $tc = New-Object System.Net.Sockets.TcpClient
        try { $t = $tc.ConnectAsync($computer, $port); if ($t.Wait(2000) -and $tc.Connected) { $reach = $true } } catch {} finally { $tc.Close() }
        if ($reach) { break }
    }
    if (-not $reach) {
        return [PSCustomObject]@{ Computer = $computer; Rows = @(); Log = @(); ConnectError = 'No answer on ports 445/135' }
    }

    if ($action -eq 'Stop' -or $action -eq 'Restart') {
        $rev = @($targets); [array]::Reverse($rev)
        foreach ($n in $rev) {
            try {
                $sc = New-Object System.ServiceProcess.ServiceController($n, $computer)
                if ($sc.Status -eq 'Stopped') { $log += New-Log $n 'Skipped' 'Already stopped' }
                else { $sc.Stop(); $sc.WaitForStatus('Stopped', $timeout); $log += New-Log $n 'Stopped' '' }
                $sc.Dispose()
            } catch { $log += New-Log $n 'Failed' ('Stop: ' + (Get-Deepest $_).Message) }
        }
    }
    if ($action -eq 'Start' -or $action -eq 'Restart') {
        foreach ($n in @($targets)) {
            try {
                $sc = New-Object System.ServiceProcess.ServiceController($n, $computer)
                if ($sc.StartType -eq 'Disabled')  { $log += New-Log $n 'Skipped' 'Service is Disabled' }
                elseif ($sc.Status -eq 'Running')  { $log += New-Log $n 'Skipped' 'Already running' }
                else { $sc.Start(); $sc.WaitForStatus('Running', $timeout); $log += New-Log $n 'Started' '' }
                $sc.Dispose()
            } catch { $log += New-Log $n 'Failed' ('Start: ' + (Get-Deepest $_).Message) }
        }
    }

    $rows = @()
    foreach ($n in $queryNames) {
        try {
            $sc = New-Object System.ServiceProcess.ServiceController($n, $computer)
            $rows += [PSCustomObject]@{ Name = $n; Status = $sc.Status.ToString(); StartType = $sc.StartType.ToString(); Detail = '' }
            $sc.Dispose()
        } catch {
            $e  = Get-Deepest $_
            $st = 'Error'
            if ($e -is [System.ComponentModel.Win32Exception] -and $e.NativeErrorCode -eq 1060) { $st = 'NotFound' }
            $rows += [PSCustomObject]@{ Name = $n; Status = $st; StartType = ''; Detail = $e.Message }
        }
    }
    $connErr = ''
    if (@($rows | Where-Object { $_.Status -ne 'Error' }).Count -eq 0) {
        $first = @($rows | Where-Object { $_.Status -eq 'Error' }) | Select-Object -First 1
        if ($first) { $connErr = $first.Detail }
    }
    [PSCustomObject]@{ Computer = $computer; Rows = $rows; Log = $log; ConnectError = $connErr }
}
function Set-RemoteStatus([string]$text, [string]$hex) { $txtRemStatus.Text = $text; $txtRemStatus.Foreground = ColorBrush $hex }
function Set-RemoteButtons([bool]$on) {
    foreach ($b in @($btnRemLoad, $btnRemStart, $btnRemStop, $btnRemRestart, $btnRemStack)) { $b.IsEnabled = $on }
}
function Get-RemoteHint([string]$msg) {
    if ($msg -match 'Access is denied')                                  { return ' - your account is not an administrator on that PC.' }
    if ($msg -match 'RPC server is unavailable|network path|445/135')    { return ' - the PC is off, the name/IP is wrong, or its firewall blocks Remote Service Management.' }
    if ($msg -match 'Time out|timed out')                                { return ' - the service did not finish within 60 seconds. Load again in a moment to check.' }
    return ''
}
function Get-RemoteHostFor($dev) {
    if ($dev.Status -in @('Online (no DNS)', 'Unresolved') -and $dev.LastKnownIP) { return [string]$dev.LastKnownIP }
    return [string]$dev.Name
}
function Get-RemoteServiceSelection([string]$Computer) {
    $display = @{}
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($def in $script:ServiceDefs) {
        $names.Add([string]$def.Name)
        $display[$def.Name] = $def.Display
    }
    foreach ($extra in $script:RemoteServiceDefs) {
        $matchesComputer = $Computer -ieq $extra.Computer -or
            $Computer -match ('^{0}\.' -f [regex]::Escape([string]$extra.Computer))
        if (-not $matchesComputer) {
            $matchesComputer = @($script:Devices | Where-Object {
                $_.Name -ieq $extra.Computer -and $_.LastKnownIP -eq $Computer
            }).Count -gt 0
        }
        if ($matchesComputer) {
            $names.Add([string]$extra.Name)
            $display[$extra.Name] = $extra.Display
        }
    }
    return [PSCustomObject]@{ Names = [string[]]$names.ToArray(); DisplayNames = $display }
}
function Start-RemoteJob([string]$Action, [string[]]$Targets) {
    $computer = $txtRemHost.Text.Trim()
    if (-not $computer) { Set-RemoteStatus 'Enter a computer name or IP first.' '#F38BA8'; return }
    if ($computer -notmatch '^[A-Za-z0-9._-]+$') { Set-RemoteStatus 'Use letters, numbers, dots, dashes or underscores only.' '#F38BA8'; return }
    if ($script:RemoteJob) { Set-RemoteStatus 'Still working on the last request...' '#89B4FA'; return }
    $selection = Get-RemoteServiceSelection $computer
    if ($Action -ne 'Query') {
        foreach ($target in $Targets) {
            if ($target -notin $selection.Names) {
                Set-RemoteStatus "The selected service is not configured for $computer. Load that computer's services again." '#F38BA8'
                return
            }
        }
    }
    $script:RemoteDisplayNames = $selection.DisplayNames
    try {
        $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($script:RemoteSvcScript.ToString()).AddArgument($computer).AddArgument($Action).AddArgument([string[]]@($Targets)).AddArgument($selection.Names)
        $script:RemoteJob = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Action = $Action }
        Set-RemoteButtons $false
        $verb = @{ Query = 'Loading services'; Start = 'Starting'; Stop = 'Stopping'; Restart = 'Restarting' }[$Action]
        Set-RemoteStatus "$verb on $computer..." '#89B4FA'
    } catch {
        $script:RemoteJob = $null
        Set-RemoteButtons $true
        Set-RemoteStatus "Could not start: $($_.Exception.Message)" '#F38BA8'
    }
}
function Complete-RemoteJob {
    $job = $script:RemoteJob
    $script:RemoteJob = $null
    Set-RemoteButtons $true
    $res = $null
    try     { $res = @($job.PS.EndInvoke($job.Handle)) | Select-Object -Last 1 }
    catch   { Set-RemoteStatus "Failed: $($_.Exception.Message)" '#F38BA8'; return }
    finally { try { $job.PS.Dispose(); $job.RS.Close(); $job.RS.Dispose() } catch {} }
    if (-not $res) { Set-RemoteStatus 'The request returned nothing.' '#F38BA8'; return }

    $display = $script:RemoteDisplayNames
    foreach ($l in @($res.Log)) {
        Add-HistoryEntry -ServiceName "$($res.Computer): $($display[$l.Name])" -Group 'Remote' -OldStatus '' -NewStatus $l.Result -Note $l.Note
    }
    $script:RemoteList.Clear()
    if ($res.ConnectError) {
        Set-RemoteStatus ("Could not reach {0}: {1}{2}" -f $res.Computer, $res.ConnectError, (Get-RemoteHint $res.ConnectError)) '#F38BA8'
        return
    }
    $notInstalled = 0
    foreach ($r in @($res.Rows)) {
        if ($r.Status -eq 'NotFound') { $notInstalled++; continue }
        $script:RemoteList.Add([PSCustomObject]@{ Display = $display[$r.Name]; Name = $r.Name; Status = $r.Status; StartType = $r.StartType })
    }
    $failed = @($res.Log | Where-Object { $_.Result -eq 'Failed' })
    $when   = (Get-Date).ToString('HH:mm:ss')
    if ($failed.Count -gt 0) {
        $f = $failed[0]
        Set-RemoteStatus ("{0} action(s) failed on {1}. {2}: {3}{4}" -f $failed.Count, $res.Computer, $display[$f.Name], $f.Note, (Get-RemoteHint $f.Note)) '#F38BA8'
    } elseif ($job.Action -eq 'Query') {
        Set-RemoteStatus ("Loaded {0} service(s) from {1} at {2} ({3} not installed there)." -f $script:RemoteList.Count, $res.Computer, $when, $notInstalled) '#A6E3A1'
    } else {
        Set-RemoteStatus ("{0} finished on {1} at {2}." -f $job.Action, $res.Computer, $when) '#A6E3A1'
    }
}
function Invoke-RemoteRowAction([string]$Action) {
    $row = $dgRemote.SelectedItem
    if (-not $row) { Set-RemoteStatus 'Select a service in the list first.' '#F9E2AF'; return }
    if ($Action -ne 'Start') {
        $ans = [System.Windows.MessageBox]::Show("$Action $($row.Display) on $($txtRemHost.Text.Trim())?`r`nAnyone using it on that PC will be interrupted.", 'Remote service', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
    }
    Start-RemoteJob $Action @([string]$row.Name)
}
$btnDevServices.Add_Click({
    $dev = $dgDevices.SelectedItem
    if ($dev) { $txtRemHost.Text = Get-RemoteHostFor $dev }
    $script:RemoteList.Clear()
    $pnlDiscover.Visibility = 'Collapsed'
    $pnlRemote.Visibility = 'Visible'
    if ($txtRemHost.Text.Trim()) { Start-RemoteJob 'Query' @() }
    else { Set-RemoteStatus 'Type a computer name or IP, then click Load Services.' '#6C7086' }
})
$btnRemClose.Add_Click({ $pnlRemote.Visibility = 'Collapsed' })
$btnRemLoad.Add_Click({ Start-RemoteJob 'Query' @() })
$txtRemHost.Add_KeyDown({ if ($_.Key -eq 'Return') { Start-RemoteJob 'Query' @() } })
$btnRemStart.Add_Click({   Invoke-RemoteRowAction 'Start' })
$btnRemStop.Add_Click({    Invoke-RemoteRowAction 'Stop' })
$btnRemRestart.Add_Click({ Invoke-RemoteRowAction 'Restart' })
$btnRemStack.Add_Click({
    # Core + API services only (SQL is left alone), in start order, skipping Disabled / not installed
    $present = @{}
    foreach ($r in $script:RemoteList) { if ($r.StartType -ne 'Disabled') { $present[$r.Name] = $true } }
    $stack = @()
    foreach ($n in $script:StartOrder) {
        $d = $script:ServiceDefs | Where-Object { $_.Name -eq $n } | Select-Object -First 1
        if ($d -and $d.Group -in @('Core', 'API') -and $present.ContainsKey($n)) { $stack += $n }
    }
    if ($stack.Count -eq 0) { Set-RemoteStatus 'Load the services first - no EMBED Core/API services were found on this PC.' '#F9E2AF'; return }
    $list = ($stack | ForEach-Object { $nn = $_; ($script:ServiceDefs | Where-Object { $_.Name -eq $nn } | Select-Object -First 1).Display }) -join "`r`n  "
    $ans = [System.Windows.MessageBox]::Show("Restart the EMBED stack on $($txtRemHost.Text.Trim())?`r`n`r`n  $list`r`n`r`nStopped in reverse order, then started in order.", 'Restart EMBED Stack', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    Start-RemoteJob 'Restart' $stack
})
# ------------------------------------------------------------
# DATABASE VERSION (header badge)
# Reads Property_Id 22608 / 22609 / 22610 (Database Version / Full / Informational) from the EMBED properties table.
# The table is found automatically: any table in a user database with Property_Id, Descriptor and Value columns.
# ------------------------------------------------------------
$script:DbVerScript = {
    param($sqlServer)
    $out = [ordered]@{ Ok = $false; Error = ''; Database = ''; Table = ''; Version = ''; Full = ''; Info = ''; Others = '' }
    function Get-Deepest($err) { $e = $err.Exception; while ($e.InnerException) { $e = $e.InnerException }; $e.Message }
    function New-Conn([string]$db) {
        $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $b['Data Source']              = $sqlServer
        $b['Initial Catalog']          = $db
        $b['Integrated Security']      = $true
        $b['TrustServerCertificate']   = $true
        $b['Connect Timeout']          = 5
        $b['Application Name']         = "EMBED  Services Dashboard $script:AppVersion"
        New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
    }
    try {
        $dbs = @()
        $cn = New-Conn 'master'
        try {
            $cn.Open()
            $cmd = $cn.CreateCommand(); $cmd.CommandTimeout = 10
            $cmd.CommandText = 'SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0 ORDER BY name'
            $rd = $cmd.ExecuteReader()
            while ($rd.Read()) { $dbs += $rd.GetString(0) }
            $rd.Close()
        } finally { $cn.Dispose() }

        $hits = @()
        foreach ($db in $dbs) {
            $c = New-Conn $db
            try {
                $c.Open()
                $cmd = $c.CreateCommand(); $cmd.CommandTimeout = 10
                $cmd.CommandText = @"
SELECT TOP 1 QUOTENAME(SCHEMA_NAME(t.schema_id)) + '.' + QUOTENAME(t.name)
FROM sys.tables t
WHERE EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.name = 'Property_Id')
  AND EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.name = 'Descriptor')
  AND EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.name = 'Value')
"@
                $tbl = $cmd.ExecuteScalar()
                if (-not $tbl -or $tbl -is [DBNull]) { continue }
                $cmd.CommandText = "SELECT Property_Id, CAST(Descriptor AS nvarchar(400)), CAST(Value AS nvarchar(400)) FROM $tbl " +
                                   "WHERE Property_Id IN (22608, 22609, 22610) OR Descriptor IN ('Database Version', 'Database Full Version', 'Database Informational Version')"
                $h = @{ Database = $db; Table = [string]$tbl; Version = ''; Full = ''; Info = '' }
                $rd = $cmd.ExecuteReader()
                while ($rd.Read()) {
                    $id   = [string]$rd.GetValue(0)
                    $desc = if ($rd.IsDBNull(1)) { '' } else { $rd.GetString(1).Trim() }
                    $val  = if ($rd.IsDBNull(2)) { '' } else { $rd.GetString(2).Trim() }
                    if     ($id -eq '22608' -or $desc -eq 'Database Version')               { $h.Version = $val }
                    elseif ($id -eq '22609' -or $desc -eq 'Database Full Version')          { $h.Full    = $val }
                    elseif ($id -eq '22610' -or $desc -eq 'Database Informational Version') { $h.Info    = $val }
                }
                $rd.Close()
                if ($h.Version -or $h.Full -or $h.Info) { $hits += $h }
            } catch {
                # no access to this database or not an EMBED database - skip it
            } finally { $c.Dispose() }
        }
        if ($hits.Count -gt 0) {
            $f = $hits[0]
            $out.Database = $f.Database; $out.Table = $f.Table
            $out.Version  = $f.Version;  $out.Full  = $f.Full; $out.Info = $f.Info
            if ($hits.Count -gt 1) {
                $out.Others = (@($hits | Select-Object -Skip 1 | ForEach-Object { "$($_.Database) = $($_.Full)$(if (-not $_.Full) { $_.Version })" }) -join ', ')
            }
        }
        $out.Ok = $true
    } catch {
        $out.Error = Get-Deepest $_
    }
    [PSCustomObject]$out
}
function Start-DbVersionCheck {
    if ($script:DbVerJob) { return }
    $script:LastDbVerCheck = Get-Date
    try {
        $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($script:DbVerScript.ToString()).AddArgument([string]$script:GuruSqlServer)
        $script:DbVerJob = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
    } catch {
        $script:DbVerJob = $null
    }
}
function Get-DbVersionText {
    $r = $script:DbVer
    if (-not $r)    { return 'Database version: not checked yet' }
    if (-not $r.Ok) { return "Database version: could not connect to $($script:GuruSqlServer) - $($r.Error)" }
    if (-not ($r.Version -or $r.Full -or $r.Info)) { return "Database version: not found on $($script:GuruSqlServer)" }
    $lines = @(
        "Database Version:               $($r.Version)",
        "Database Full Version:          $($r.Full)",
        "Database Informational Version: $($r.Info)",
        "Database:                       $($r.Database) on $($script:GuruSqlServer)"
    )
    if ($r.Others) { $lines += "Other EMBED databases:          $($r.Others)" }
    return ($lines -join "`r`n")
}
function Complete-DbVersionCheck {
    $job = $script:DbVerJob
    $script:DbVerJob = $null
    $res = $null
    try     { $res = @($job.PS.EndInvoke($job.Handle)) | Select-Object -Last 1 }
    catch   { $res = [PSCustomObject]@{ Ok = $false; Error = $_.Exception.Message; Version = ''; Full = ''; Info = '' } }
    finally { try { $job.PS.Dispose(); $job.RS.Close(); $job.RS.Dispose() } catch {} }
    if (-not $res) { return }
    $prev = $script:DbVer
    $script:DbVer = $res

    if (-not $res.Ok) {
        $txtDbVer.Text         = 'No SQL connection'
        $txtDbVer.Foreground   = ColorBrush '#F38BA8'
        $dbBadge.Background    = ColorBrush '#30F38BA8'
    } elseif (-not ($res.Version -or $res.Full -or $res.Info)) {
        $txtDbVer.Text         = 'Not found'
        $txtDbVer.Foreground   = ColorBrush '#F9E2AF'
        $dbBadge.Background    = ColorBrush '#30F9E2AF'
    } else {
        $shown = $res.Full; if (-not $shown) { $shown = $res.Version }; if (-not $shown) { $shown = $res.Info }
        $txtDbVer.Text         = $shown
        $txtDbVer.Foreground   = ColorBrush '#CBA6F7'
        $dbBadge.Background    = ColorBrush '#30CBA6F7'
    }
    $dbBadge.ToolTip = (Get-DbVersionText) + "`r`n`r`nClick to copy"

    # Log upgrades / changes to History
    if ($prev -and $prev.Ok -and $res.Ok -and $prev.Full -and $res.Full -and $prev.Full -ne $res.Full) {
        Add-HistoryEntry -ServiceName "Database $($res.Database)" -Group 'SQL' -OldStatus $prev.Full -NewStatus $res.Full -Note 'Database version changed'
    }
}
$dbBadge.Add_MouseLeftButtonUp({
    try { [System.Windows.Clipboard]::SetText((Get-DbVersionText)); $statusBar.Text = 'Database version copied to clipboard.' }
    catch { $statusBar.Text = "Copy failed: $($_.Exception.Message)" }
})
# ------------------------------------------------------------
# SOFTWARE (place installers on a station and optionally run them)
# ------------------------------------------------------------
$dgPackages.ItemsSource = $script:Packages
# Background job: copy the installer (or its whole folder) to \\PC\C$\<station folder>\<package>, verify it,
# then optionally start it on the station through WMI and wait for the exit code.
$script:SoftwareScript = {
    param($computer, $pkgName, $installer, $wholeFolder, $instArgs, $stationRoot, $doInstall, $q, $timeoutMin)
    function Log([string]$m) { $q.Enqueue(('{0}  {1}' -f (Get-Date).ToString('HH:mm:ss'), $m)) }
    function Get-Deepest($err) { $e = $err.Exception; while ($e.InnerException) { $e = $e.InnerException }; $e.Message }
    $action = 'Copy'; if ($doInstall) { $action = 'Install' }
    $res = [ordered]@{ Ok = $false; Computer = $computer; Package = $pkgName; Action = $action; Message = ''; ExitCode = $null }
    try {
        Log "==== $action '$pkgName' -> $computer ===="
        $ok = $false
        $tc = New-Object System.Net.Sockets.TcpClient
        try { $t = $tc.ConnectAsync($computer, 445); $ok = ($t.Wait(3000) -and $tc.Connected) } catch {} finally { $tc.Close() }
        if (-not $ok) { throw "$computer is not answering on port 445 (file sharing). It may be off, the name may be wrong, or its firewall blocks it." }
        if (-not (Test-Path -LiteralPath $installer)) { throw "Installer not found on this server: $installer" }

        $file      = Split-Path $installer -Leaf
        $srcDir    = Split-Path $installer -Parent
        $destLocal = Join-Path $stationRoot $pkgName
        $destUnc   = '\\' + $computer + '\' + $destLocal.Substring(0, 1) + '$' + $destLocal.Substring(2)
        Log "Station folder: $destLocal"
        if (Test-Path -LiteralPath $destUnc) { Log 'Removing the previous copy...'; Remove-Item -LiteralPath $destUnc -Recurse -Force }
        New-Item -ItemType Directory -Path $destUnc -Force | Out-Null

        if ($wholeFolder) {
            $size = (Get-ChildItem -LiteralPath $srcDir -Recurse -File | Measure-Object Length -Sum).Sum
            Log ('Copying folder {0} ({1:N1} MB)...' -f $srcDir, ($size / 1MB))
            $rcArgs = @($srcDir, $destUnc, '/E')
        } else {
            Log ('Copying {0} ({1:N1} MB)...' -f $file, ((Get-Item -LiteralPath $installer).Length / 1MB))
            $rcArgs = @($srcDir, $destUnc, $file)
        }
        $rcOut  = & robocopy.exe @rcArgs /R:2 /W:3 /NP /NFL /NDL /NJH 2>&1
        $rcCode = $LASTEXITCODE
        foreach ($l in @($rcOut)) { $s = "$l".Trim(); if ($s -match '^(Dirs|Files|Bytes|Times|Speed)\s*:') { Log "  $s" } }
        if ($rcCode -ge 8) { throw "Copy failed (robocopy code $rcCode)." }
        $dst = Join-Path $destUnc $file
        if (-not (Test-Path -LiteralPath $dst)) { throw 'The installer is missing on the station after the copy.' }
        if ((Get-Item -LiteralPath $dst).Length -ne (Get-Item -LiteralPath $installer).Length) { throw 'The installer on the station does not match the server copy (size differs).' }
        Log 'Copy verified.'
        if (-not $doInstall) {
            $res.Ok = $true; $res.Message = "Copied to $destLocal"
            Log 'Done.'
            return [PSCustomObject]$res
        }

        $instLocal = Join-Path $destLocal $file
        $exitLocal = Join-Path $destLocal '_exitcode.txt'
        $exitUnc   = Join-Path $destUnc '_exitcode.txt'
        if ($file -like '*.msi') {
            $a = $instArgs; if (-not $a) { $a = '/qn /norestart' }
            $inner = "msiexec.exe /i `"$instLocal`" $a /l*v `"$(Join-Path $destLocal '_install.log')`""
        } else {
            $inner = ("`"$instLocal`" $instArgs").Trim()
        }
        # cmd records the installer's exit code in a file so we can read it back over the share
        $cmdLine = 'cmd.exe /v:on /c "' + $inner + ' & echo !errorlevel!>"' + $exitLocal + '""'
        Log "Running on station: $inner"
        $cs = New-CimSession -ComputerName $computer -SessionOption (New-CimSessionOption -Protocol Dcom) -OperationTimeoutSec 30 -ErrorAction Stop
        try {
            $r = Invoke-CimMethod -CimSession $cs -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdLine; CurrentDirectory = $destLocal } -ErrorAction Stop
            if ($r.ReturnValue -ne 0) { throw "Windows refused to start the installer (Win32_Process code $($r.ReturnValue))." }
            $procId = $r.ProcessId
            Log "Installer started (PID $procId). Waiting for it to finish (max $timeoutMin min)..."
            $start = Get-Date; $deadline = $start.AddMinutes($timeoutMin); $gone = $null; $lastNote = $start
            while ($true) {
                Start-Sleep -Seconds 5
                if (Test-Path -LiteralPath $exitUnc) { break }
                $p = Get-CimInstance -CimSession $cs -ClassName Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
                if (-not $p) {
                    if (-not $gone) { $gone = Get-Date } elseif (((Get-Date) - $gone).TotalSeconds -gt 15) { break }
                }
                if ((Get-Date) -gt $deadline) { throw "The installer is still running after $timeoutMin minutes (PID $procId on $computer). It is probably waiting for input - the install arguments must make it silent." }
                if (((Get-Date) - $lastNote).TotalSeconds -ge 60) { $lastNote = Get-Date; Log ('Still installing... {0:N0} min' -f ((Get-Date) - $start).TotalMinutes) }
            }
        } finally { Remove-CimSession $cs -ErrorAction SilentlyContinue }
        if (-not (Test-Path -LiteralPath $exitUnc)) { throw 'The installer ended but no exit code was recorded.' }
        $ec = 0
        if (-not [int]::TryParse(([string](Get-Content -LiteralPath $exitUnc -Raw)).Trim(), [ref]$ec)) { throw 'Could not read the installer exit code.' }
        $res.ExitCode = $ec
        switch ($ec) {
            0       { $res.Ok = $true; $res.Message = 'Installed successfully' }
            3010    { $res.Ok = $true; $res.Message = 'Installed - restart the station to finish' }
            1641    { $res.Ok = $true; $res.Message = 'Installed - the installer is restarting the station' }
            1618    { $res.Message = 'Another installation is already running on the station - try again in a few minutes (1618)' }
            1603    { $res.Message = "Install failed (1603 fatal error). See $destLocal on the station for logs" }
            1602    { $res.Message = 'Install was cancelled (1602)' }
            default { $res.Message = "Installer exited with code $ec" }
        }
        Log "Exit code $ec - $($res.Message)"
    } catch {
        $m = Get-Deepest $_
        if ($m -match 'Access is denied|Access to the path') { $m += ' - your account must be an administrator on the station.' }
        if ($m -match 'RPC server is unavailable')            { $m += ' - the station firewall blocks remote management (WMI).' }
        $res.Message = $m
        Log "ERROR: $m"
    }
    [PSCustomObject]$res
}
function Set-SwStatus([string]$text, [string]$hex) { $txtSwStatus.Text = $text; $txtSwStatus.Foreground = ColorBrush $hex }
function Set-SwButtons([bool]$on) { foreach ($b in @($btnSwCopy, $btnSwInstall, $btnSwRemove)) { $b.IsEnabled = $on } }
function Get-SwStation {
    $c = $txtSwStation.Text.Trim()
    if (-not $c) { Set-SwStatus 'Enter the station name or IP first.' '#F38BA8'; return $null }
    if ($c -notmatch '^[A-Za-z0-9._-]+$') { Set-SwStatus 'Station: use letters, numbers, dots, dashes or underscores only.' '#F38BA8'; return $null }
    return $c
}
function Start-SoftwareJob([bool]$Install) {
    if ($script:SwJob) { Set-SwStatus 'Still working on the last request...' '#89B4FA'; return }
    $pkg = $dgPackages.SelectedItem
    if (-not $pkg) { Set-SwStatus 'Select a package in the list first.' '#F9E2AF'; return }
    $pc = Get-SwStation; if (-not $pc) { return }
    if ($Install) {
        $ans = [System.Windows.MessageBox]::Show("Install '$($pkg.Name)' on $pc now?`r`n`r`nClose the application on that station first. The installer runs silently with:`r`n$($pkg.Installer) $($pkg.Args)", 'Copy + Install', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
    }
    try {
        $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($script:SoftwareScript.ToString()).AddArgument($pc).AddArgument([string]$pkg.Name).AddArgument([string]$pkg.Installer).AddArgument([bool]$pkg.WholeFolder).AddArgument([string]$pkg.Args).AddArgument([string]$script:SoftwareConfig['StationRoot']).AddArgument($Install).AddArgument($script:SwLog).AddArgument([int]$script:SwTimeoutMin)
        $script:SwJob = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Pkg = $pkg }
        Set-SwButtons $false
        $pkg.Result = 'Working...'; $dgPackages.Items.Refresh()
        $verb = 'Copying'; if ($Install) { $verb = 'Copying and installing' }
        Set-SwStatus "$verb '$($pkg.Name)' on $pc..." '#89B4FA'
    } catch {
        $script:SwJob = $null
        Set-SwButtons $true
        Set-SwStatus "Could not start: $($_.Exception.Message)" '#F38BA8'
    }
}
function Complete-SoftwareJob {
    $job = $script:SwJob
    $script:SwJob = $null
    Set-SwButtons $true
    $res = $null
    try     { $res = @($job.PS.EndInvoke($job.Handle)) | Select-Object -Last 1 }
    catch   { $res = [PSCustomObject]@{ Ok = $false; Computer = $txtSwStation.Text.Trim(); Package = $job.Pkg.Name; Action = ''; Message = $_.Exception.Message } }
    finally { try { $job.PS.Dispose(); $job.RS.Close(); $job.RS.Dispose() } catch {} }
    if (-not $res) { Set-SwStatus 'The request returned nothing.' '#F38BA8'; return }
    $when = (Get-Date).ToString('MM-dd HH:mm')
    $job.Pkg.Result = "$($res.Computer): $($res.Message) ($when)"
    $dgPackages.Items.Refresh()
    $state = 'Failed'
    if ($res.Ok) { $state = 'Copied'; if ($res.Action -eq 'Install') { $state = 'Installed' } }
    Add-HistoryEntry -ServiceName "$($res.Computer): $($res.Package)" -Group 'Software' -OldStatus '' -NewStatus $state -Note $res.Message
    if ($res.Ok) { Set-SwStatus "$($res.Package) on $($res.Computer): $($res.Message)" '#A6E3A1' }
    else         { Set-SwStatus "$($res.Package) on $($res.Computer): $($res.Message)" '#F38BA8' }
    if (-not $window.IsVisible) {
        try { $script:TrayIcon.ShowBalloonTip(6000, 'EMBED Software', "$($res.Package) on $($res.Computer): $($res.Message)", [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
    }
}
function Get-SafePackageName([string]$n) {
    $n = ($n -replace '[^A-Za-z0-9._ -]', '_').Trim(' .')
    if (-not $n) { $n = 'Package' }
    $base = $n; $i = 2
    while (@($script:Packages | Where-Object { $_.Name -eq $n }).Count -gt 0) { $n = "$base ($i)"; $i++ }
    return $n
}
$dgPackages.Add_CellEditEnding({
    # save after WPF has pushed the edited value into the package object
    $window.Dispatcher.BeginInvoke([Action]{ Save-AllConfig }, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
})
$btnSwCopy.Add_Click({    Start-SoftwareJob $false })
$btnSwInstall.Add_Click({ Start-SoftwareJob $true })
$btnSwOpen.Add_Click({
    $pc = Get-SwStation; if (-not $pc) { return }
    $root = [string]$script:SoftwareConfig['StationRoot']
    $sub  = $root; $pkg = $dgPackages.SelectedItem
    if ($pkg) { $sub = Join-Path $root $pkg.Name }
    $unc = '\\' + $pc + '\' + $sub.Substring(0, 1) + '$' + $sub.Substring(2)
    Start-Process explorer.exe -ArgumentList "`"$unc`""
})
$btnSwRemove.Add_Click({
    $pkg = $dgPackages.SelectedItem
    if (-not $pkg) { Set-SwStatus 'Select a package first.' '#F9E2AF'; return }
    $ans = [System.Windows.MessageBox]::Show("Remove '$($pkg.Name)' from the package list?`r`n(Nothing is deleted from the server or stations.)", 'Remove package', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    [void]$script:Packages.Remove($pkg)
    Save-AllConfig
    Set-SwStatus 'Package removed.' '#6C7086'
})
$btnPkgBrowse.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Installers (*.exe;*.msi)|*.exe;*.msi|All files (*.*)|*.*'
    if ($txtPkgPath.Text -and (Test-Path -LiteralPath (Split-Path $txtPkgPath.Text -Parent) -ErrorAction SilentlyContinue)) { $dlg.InitialDirectory = Split-Path $txtPkgPath.Text -Parent }
    elseif (Test-Path -LiteralPath $script:EcsDir) { $dlg.InitialDirectory = $script:EcsDir }
    if ($dlg.ShowDialog($window)) {
        $txtPkgPath.Text = $dlg.FileName
        if (-not $txtPkgName.Text.Trim()) { $txtPkgName.Text = [IO.Path]::GetFileNameWithoutExtension($dlg.FileName) }
    }
})
$btnPkgAdd.Add_Click({
    $name = $txtPkgName.Text.Trim()
    $path = $txtPkgPath.Text.Trim().Trim('"')
    if (-not $name) { Set-SwStatus 'Enter a package name.' '#F38BA8'; return }
    if ($name -notmatch '^[A-Za-z0-9._ ()-]+$' -or $name -match '^\.+$') { Set-SwStatus 'Package name: letters, numbers, spaces, dots, dashes, underscores only.' '#F38BA8'; return }
    if (@($script:Packages | Where-Object { $_.Name -eq $name }).Count -gt 0) { Set-SwStatus "A package called '$name' already exists." '#F38BA8'; return }
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { Set-SwStatus 'Installer file not found on this server.' '#F38BA8'; return }
    $script:Packages.Add((New-PackageObject $name $path ([bool]$chkPkgFolder.IsChecked) $txtPkgArgs.Text.Trim()))
    Save-AllConfig
    $txtPkgName.Clear(); $txtPkgPath.Clear(); $txtPkgArgs.Clear()
    Set-SwStatus "Added package '$name'." '#A6E3A1'
})
$btnPkgScan.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = 'Pick the server folder that holds the installers'
    if (Test-Path -LiteralPath $script:EcsDir) { $fb.SelectedPath = $script:EcsDir }
    if ($fb.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $root = $fb.SelectedPath.TrimEnd('\')
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in '.exe', '.msi' } | Select-Object -First 60)
    $added = 0
    foreach ($f in $files) {
        if (@($script:Packages | Where-Object { $_.Installer -eq $f.FullName }).Count -gt 0) { continue }
        $inSub = ($f.DirectoryName.TrimEnd('\') -ne $root)
        $nm = $f.BaseName; if ($inSub) { $nm = "$($f.Directory.Name) - $($f.BaseName)" }
        $script:Packages.Add((New-PackageObject (Get-SafePackageName $nm) $f.FullName $inSub ''))
        $added++
    }
    if ($added -gt 0) { Save-AllConfig }
    Set-SwStatus "Scan found $($files.Count) installer(s), added $added. Double-click Install arguments to set the silent switches before using Copy + Install." '#A6E3A1'
})
$btnSwRootSave.Add_Click({
    $r = $txtSwRoot.Text.Trim().TrimEnd('\')
    if ($r -notmatch '^[A-Za-z]:\\[^*?"<>|]+$') { Set-SwStatus 'Station folder must be a local path like C:\EMBED\Installers' '#F38BA8'; return }
    $script:SoftwareConfig['StationRoot'] = $r
    $txtSwRoot.Text = $r
    Save-AllConfig
    Set-SwStatus "Station folder saved: $r" '#A6E3A1'
})
$btnDevSoftware.Add_Click({
    $dev = $dgDevices.SelectedItem
    if ($dev) { $txtSwStation.Text = Get-RemoteHostFor $dev }
    $tabSoftware.IsSelected = $true
})
$txtSwRoot.Text = [string]$script:SoftwareConfig['StationRoot']
# ------------------------------------------------------------
# TIMERS (service refresh on Settings, device check on Devices)
# ------------------------------------------------------------
function Initialize-TimerUi {
    $txtRefreshEvery.Text = [string]$script:RefreshSecs
    $txtRefreshHint.Text  = "= $(Format-Countdown $script:RefreshSecs)  (10 sec to 90 min)"
    $txtDevEvery.Text     = [string]$script:DeviceSecs
}
function Set-TimersStatus([string]$text, [string]$hex) { $txtTimersStatus.Text = $text; $txtTimersStatus.Foreground = ColorBrush $hex }
$btnTimersSave.Add_Click({
    $v = 0
    if (-not [int]::TryParse($txtRefreshEvery.Text.Trim(), [ref]$v) -or $v -lt 10 -or $v -gt 5400) {
        Set-TimersStatus 'Service refresh must be a number from 10 to 5400 seconds.' '#F38BA8'; return
    }
    $script:RefreshSecs   = $v
    $script:CountdownSecs = $v
    $txtCountdown.Text    = Format-Countdown $v
    Save-AllConfig
    Initialize-TimerUi
    Set-TimersStatus ("Saved at {0}. Services refresh every {1}." -f (Get-Date).ToString('HH:mm:ss'), (Format-Countdown $v)) '#A6E3A1'
})
function Apply-DeviceInterval {
    $v = 0
    if (-not [int]::TryParse($txtDevEvery.Text.Trim(), [ref]$v) -or $v -lt 30 -or $v -gt 3600) {
        $txtDevStatus.Text = 'Device check must be 30 to 3600 seconds.'
        $txtDevEvery.Text  = [string]$script:DeviceSecs
        return
    }
    if ($v -eq $script:DeviceSecs) { return }
    $script:DeviceSecs      = $v
    $script:DeviceCountdown = $v
    Save-AllConfig
    $txtDevStatus.Text = "Devices are now checked every $(Format-Countdown $v)."
}
$txtDevEvery.Add_KeyDown({ if ($_.Key -eq 'Return') { Apply-DeviceInterval } })
$txtDevEvery.Add_LostFocus({ Apply-DeviceInterval })
# ------------------------------------------------------------
# SQL TAB (backups, file sizes, database version) - read-only
# ------------------------------------------------------------
$script:SqlScript = {
    param($sqlServer, $knownDb)
    $o = [ordered]@{
        Ok = $false; Error = ''; Notes = @()
        ServerName = ''; Edition = ''; ProductVersion = ''; Level = ''; UpdateLevel = ''; Friendly = ''; StartTime = $null
        Database = ''; DbVersion = ''; DbFull = ''; DbInfo = ''
        Recovery = ''; LogReuseWait = ''
        Files = @(); DataMB = 0.0; DataUsedMB = 0.0; LogMB = 0.0; LogUsedMB = 0.0
        BkFull = $null; BkDiff = $null; BkLog = $null; LastPath = ''; DefaultPath = ''
    }
    function Get-Deepest($err) { $e = $err.Exception; while ($e.InnerException) { $e = $e.InnerException }; $e.Message }
    function New-Conn([string]$db) {
        $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $b['Data Source']            = $sqlServer
        $b['Initial Catalog']        = $db
        $b['Integrated Security']    = $true
        $b['TrustServerCertificate'] = $true
        $b['Connect Timeout']        = 5
        $b['Application Name']       = "EMBED Services Dashboard $($script:AppVersion)"
        New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
    }
    function Get-Rows($conn, [string]$sql, [hashtable]$prm) {
        $cmd = $conn.CreateCommand(); $cmd.CommandTimeout = 20; $cmd.CommandText = $sql
        if ($prm) { foreach ($k in $prm.Keys) { [void]$cmd.Parameters.AddWithValue($k, $prm[$k]) } }
        $dt = New-Object System.Data.DataTable
        $dt.Load($cmd.ExecuteReader())
        foreach ($r in $dt.Rows) {
            $h = [ordered]@{}
            foreach ($c in $dt.Columns) { $v = $r[$c]; if ($v -is [DBNull]) { $v = $null }; $h[$c.ColumnName] = $v }
            [PSCustomObject]$h
        }
    }
    $propSql = "SELECT TOP 1 QUOTENAME(SCHEMA_NAME(t.schema_id)) + '.' + QUOTENAME(t.name) AS T FROM sys.tables t " +
               "WHERE EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.name = 'Property_Id') " +
               "AND EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.name = 'Descriptor') " +
               "AND EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.name = 'Value')"
    $cn = $null
    try {
        $cn = New-Conn 'master'
        $cn.Open()
        # SQL Server
        $s = @(Get-Rows $cn "SELECT CAST(@@SERVERNAME AS nvarchar(256)) AS ServerName, CAST(SERVERPROPERTY('Edition') AS nvarchar(256)) AS Edition, CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)) AS PV, CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(64)) AS PL, CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(64)) AS PU" $null)[0]
        $o.ServerName = [string]$s.ServerName; $o.Edition = [string]$s.Edition
        $o.ProductVersion = [string]$s.PV; $o.Level = [string]$s.PL; $o.UpdateLevel = [string]$s.PU
        if ($o.ProductVersion -match '^(\d+)\.(\d+)') {
            $maj = [int]$Matches[1]; $min = [int]$Matches[2]
            $yr = switch ($maj) { 17 {'2025'} 16 {'2022'} 15 {'2019'} 14 {'2017'} 13 {'2016'} 12 {'2014'} 11 {'2012'} 10 { if ($min -ge 50) {'2008 R2'} else {'2008'} } default {''} }
            $o.Friendly = ("SQL Server $yr").Trim()
        }
        try { $o.StartTime = (@(Get-Rows $cn 'SELECT sqlserver_start_time AS T FROM sys.dm_os_sys_info' $null)[0]).T }
        catch { $o.Notes += 'Uptime needs VIEW SERVER STATE permission.' }

        # Default backup folder
        try { $o.DefaultPath = [string](@(Get-Rows $cn "SELECT CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(512)) AS P" $null)[0]).P } catch {}
        if (-not $o.DefaultPath) {
            try {
                $rr = @(Get-Rows $cn "EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory'" $null)
                if ($rr.Count -gt 0) { $o.DefaultPath = [string]$rr[0].Data }
            } catch {}
        }

        # Which database is EMBED's? Use the one the version badge found, otherwise look for the properties table
        $dbs = @(Get-Rows $cn 'SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0 ORDER BY name' $null | ForEach-Object { [string]$_.name })
        $order = @(); if ($knownDb -and ($dbs -contains $knownDb)) { $order += $knownDb }; $order += @($dbs | Where-Object { $_ -ne $knownDb })
        foreach ($db in $order) {
            $c = New-Conn $db
            try {
                $c.Open()
                $t = @(Get-Rows $c $propSql $null)
                if ($t.Count -eq 0 -or -not $t[0].T) { continue }
                $vals = @(Get-Rows $c ("SELECT CAST(Property_Id AS nvarchar(20)) AS Id, CAST(Descriptor AS nvarchar(400)) AS D, CAST(Value AS nvarchar(400)) AS V FROM $($t[0].T) " +
                          "WHERE Property_Id IN (22608, 22609, 22610) OR Descriptor IN ('Database Version', 'Database Full Version', 'Database Informational Version')") $null)
                if ($vals.Count -eq 0) { continue }
                $o.Database = $db
                foreach ($v in $vals) {
                    $val = ([string]$v.V).Trim(); $d = ([string]$v.D).Trim()
                    if     ($v.Id -eq '22608' -or $d -eq 'Database Version')               { $o.DbVersion = $val }
                    elseif ($v.Id -eq '22609' -or $d -eq 'Database Full Version')          { $o.DbFull    = $val }
                    elseif ($v.Id -eq '22610' -or $d -eq 'Database Informational Version') { $o.DbInfo    = $val }
                }
                # Files (size + space used) - must run inside the database
                foreach ($f in @(Get-Rows $c "SELECT type_desc AS FileType, name AS Name, physical_name AS Path, CAST(size AS bigint) * 8 / 1024.0 AS SizeMB, CAST(FILEPROPERTY(name, 'SpaceUsed') AS bigint) * 8 / 1024.0 AS UsedMB FROM sys.database_files" $null)) {
                    $o.Files += $f
                    $sz = [double]$f.SizeMB; $us = 0.0; if ($null -ne $f.UsedMB) { $us = [double]$f.UsedMB }
                    if ($f.FileType -eq 'LOG') { $o.LogMB += $sz; $o.LogUsedMB += $us }
                    elseif ($f.FileType -eq 'ROWS') { $o.DataMB += $sz; $o.DataUsedMB += $us }
                }
                break
            } catch {
                # no access / not EMBED - try the next database
            } finally { $c.Dispose() }
        }
        if (-not $o.Database) { $o.Notes += 'EMBED database not found (no Database Version property in any database).' }
        else {
            $d = @(Get-Rows $cn 'SELECT recovery_model_desc AS R, log_reuse_wait_desc AS W FROM sys.databases WHERE name = @n' @{ '@n' = $o.Database })[0]
            $o.Recovery = [string]$d.R; $o.LogReuseWait = [string]$d.W
            # Backup history from msdb
            try {
                foreach ($type in 'D', 'I', 'L') {
                    $b = @(Get-Rows $cn ("SELECT TOP 1 b.backup_finish_date AS Finished, b.backup_size / 1048576.0 AS SizeMB, b.is_copy_only AS CopyOnly, mf.physical_device_name AS Device, mf.device_type AS DevType " +
                           "FROM msdb.dbo.backupset b JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = b.media_set_id " +
                           "WHERE b.database_name = @n AND b.type = @t ORDER BY b.backup_finish_date DESC") @{ '@n' = $o.Database; '@t' = $type })
                    $val = $null; if ($b.Count -gt 0) { $val = $b[0] }
                    switch ($type) { 'D' { $o.BkFull = $val } 'I' { $o.BkDiff = $val } 'L' { $o.BkLog = $val } }
                }
                $latest = @($o.BkFull, $o.BkDiff, $o.BkLog) | Where-Object { $_ } | Sort-Object { $_.Finished } -Descending | Select-Object -First 1
                if ($latest) { $o.LastPath = [string]$latest.Device }
            } catch { $o.Notes += "Backup history could not be read: $(Get-Deepest $_)" }
        }
        $o.Ok = $true
    } catch {
        $o.Error = Get-Deepest $_
    } finally { if ($cn) { $cn.Dispose() } }
    [PSCustomObject]$o
}
function Start-SqlCheck {
    if ($script:SqlJob) { return }
    $script:LastSqlCheck = Get-Date
    $known = ''
    if ($script:DbVer -and $script:DbVer.Ok -and $script:DbVer.PSObject.Properties['Database']) { $known = [string]$script:DbVer.Database }
    try {
        $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($script:SqlScript.ToString()).AddArgument([string]$script:GuruSqlServer).AddArgument($known)
        $script:SqlJob = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
        $btnSqlRefresh.IsEnabled = $false
        Set-SqlStatus "Reading SQL Server $($script:GuruSqlServer)..." '#89B4FA'
    } catch {
        $script:SqlJob = $null
        $btnSqlRefresh.IsEnabled = $true
        Set-SqlStatus "Could not start the SQL check: $($_.Exception.Message)" '#F38BA8'
    }
}
function Set-SqlStatus([string]$text, [string]$hex) { $txtSqlStatus.Text = $text; $txtSqlStatus.Foreground = ColorBrush $hex }
function Format-Size([double]$mb) { if ($mb -ge 1024) { '{0:N1} GB' -f ($mb / 1024) } else { '{0:N0} MB' -f $mb } }
function Format-Age($when) {
    if (-not $when) { return '' }
    $ts = (Get-Date) - [datetime]$when
    if ($ts.TotalMinutes -lt 1) { return 'just now' }
    if ($ts.TotalHours   -lt 1) { return ('{0} min ago' -f [int]$ts.TotalMinutes) }
    if ($ts.TotalDays    -lt 1) { return ('{0}h {1}m ago' -f $ts.Hours, $ts.Minutes) }
    return ('{0}d {1}h ago' -f $ts.Days, $ts.Hours)
}
# Text for one backup row, plus the colour of its dot
function Get-BackupLine($bk, [string]$kind, [string]$recovery) {
    if (-not $bk) {
        switch ($kind) {
            'Full' { return @('No full backup on record', '#F38BA8') }
            'Diff' { return @('None on record', '#6C7086') }
            'Log'  {
                if ($recovery -eq 'SIMPLE') { return @('Not used (Simple recovery)', '#6C7086') }
                return @("None on record - the log keeps growing until a log backup runs ($recovery recovery)", '#F38BA8')
            }
        }
    }
    $when = [datetime]$bk.Finished
    $age  = ((Get-Date) - $when).TotalDays
    $txt  = '{0}  ({1})  ·  {2}' -f $when.ToString('yyyy-MM-dd HH:mm'), (Format-Age $when), (Format-Size ([double]$bk.SizeMB))
    if ($bk.CopyOnly) { $txt += '  ·  copy-only' }
    $color = '#A6E3A1'
    switch ($kind) {
        'Full' { if ($age -gt $script:BackupRedDays) { $color = '#F38BA8' } elseif ($age -gt $script:BackupWarnDays) { $color = '#F9E2AF' } }
        'Diff' { $color = '#89B4FA' }
        'Log'  { if ($recovery -eq 'SIMPLE') { $color = '#6C7086' } elseif ($age -gt 1) { $color = '#F9E2AF' } }
    }
    return @($txt, $color)
}
# Turn a path as SQL sees it into one this PC can open
function Get-OpenablePath([string]$p) {
    if (-not $p) { return '' }
    if ($p -like '\\*') { return $p }
    if ($p -notmatch '^[A-Za-z]:\\') { return '' }                     # e.g. a backup-software device name
    $sqlHost = ($script:GuruSqlServer -split '[\\,]')[0]
    if ($sqlHost -in @('localhost', '.', '(local)', '127.0.0.1', '') -or $sqlHost -ieq $env:COMPUTERNAME) { return $p }
    return '\\' + $sqlHost + '\' + $p.Substring(0, 1) + '$' + $p.Substring(2)
}
function Open-SqlFolder([string]$p, [bool]$IsFile) {
    $open = Get-OpenablePath $p
    if (-not $open) { Set-SqlStatus "That location can't be opened from here: $p" '#F9E2AF'; return }
    if ($IsFile) {
        if (Test-Path -LiteralPath $open) { Start-Process explorer.exe -ArgumentList "/select,`"$open`""; return }
        $open = Split-Path $open -Parent
    }
    if (Test-Path -LiteralPath $open) { Start-Process explorer.exe -ArgumentList "`"$open`"" }
    else { Set-SqlStatus "Folder not reachable from this PC: $open" '#F9E2AF' }
}
function Complete-SqlCheck {
    $job = $script:SqlJob
    $script:SqlJob = $null
    $btnSqlRefresh.IsEnabled = $true
    $r = $null
    try     { $r = @($job.PS.EndInvoke($job.Handle)) | Select-Object -Last 1 }
    catch   { $r = [PSCustomObject]@{ Ok = $false; Error = $_.Exception.Message } }
    finally { try { $job.PS.Dispose(); $job.RS.Close(); $job.RS.Dispose() } catch {} }
    if (-not $r) { $r = [PSCustomObject]@{ Ok = $false; Error = 'The SQL check returned nothing.' } }
    $script:SqlInfo = $r
    $when = (Get-Date).ToString('HH:mm:ss')
    if (-not $r.Ok) { Set-SqlStatus "Could not read SQL Server $($script:GuruSqlServer) at ${when}: $($r.Error)" '#F38BA8'; return }

    # Version
    $full = $r.DbFull; if (-not $full) { $full = $r.DbVersion }; if (-not $full) { $full = 'Not found' }
    $txtSqlDbFull.Text = $full
    $sub = @()
    if ($r.DbVersion) { $sub += "Version $($r.DbVersion)" }
    if ($r.DbInfo)    { $sub += "Informational $($r.DbInfo)" }
    if ($r.Database)  { $sub += "Database $($r.Database)" }
    $txtSqlDbSub.Text = $sub -join '   ·   '

    # Backups
    foreach ($pair in @(@($r.BkFull, 'Full', $txtBkFull, $dotBkFull), @($r.BkDiff, 'Diff', $txtBkDiff, $dotBkDiff), @($r.BkLog, 'Log', $txtBkLog, $dotBkLog))) {
        $line = Get-BackupLine $pair[0] $pair[1] $r.Recovery
        $pair[2].Text = $line[0]
        $pair[3].Fill = ColorBrush $line[1]
    }
    if ($r.LastPath) {
        $txtBkPath.Text = $r.LastPath
        if (-not (Get-OpenablePath $r.LastPath)) { $txtBkPath.Text += '   (made by backup software, not a file path)' }
    } else { $txtBkPath.Text = 'No backups on record' }
    $txtBkDefault.Text = if ($r.DefaultPath) { $r.DefaultPath } else { 'Unknown (needs SQL 2019+ or sysadmin rights to read)' }
    $btnBkOpenLast.IsEnabled    = [bool](Get-OpenablePath $r.LastPath)
    $btnBkOpenDefault.IsEnabled = [bool](Get-OpenablePath $r.DefaultPath)

    # Files
    $txtSqlLogSize.Text  = if ($r.Database) { Format-Size $r.LogMB } else { '—' }
    $txtSqlDataSize.Text = if ($r.Database) { Format-Size $r.DataMB } else { '—' }
    $txtSqlLogUsed.Text  = if ($r.LogMB -gt 0) { '{0} used ({1:N0}%)' -f (Format-Size $r.LogUsedMB), ($r.LogUsedMB / $r.LogMB * 100) } else { '' }
    $txtSqlDataUsed.Text = if ($r.DataMB -gt 0) { '{0} used ({1:N0}%)' -f (Format-Size $r.DataUsedMB), ($r.DataUsedMB / $r.DataMB * 100) } else { '' }
    $txtSqlRecovery.Text = if ($r.Recovery) { $r.Recovery.Substring(0,1) + $r.Recovery.Substring(1).ToLower() } else { '—' }
    $txtSqlLogWait.Text  = if ($r.LogReuseWait) { "Log waiting on: $($r.LogReuseWait)" } else { '' }
    $txtSqlFiles.Text    = (@($r.Files) | ForEach-Object { '{0,-5} {1,10}  {2}' -f ($(if ($_.FileType -eq 'ROWS') { 'DATA' } else { $_.FileType })), (Format-Size ([double]$_.SizeMB)), $_.Path }) -join "`r`n"
    $warn = @()
    if ($r.Recovery -and $r.Recovery -ne 'SIMPLE' -and -not $r.BkLog) { $warn += "⚠ $($r.Recovery) recovery with no log backups - the log file will keep growing. Set up log backups or switch to Simple recovery." }
    if ($r.DataMB -gt 0 -and $r.LogMB -gt $r.DataMB) { $warn += '⚠ The log file is bigger than the data file.' }
    if ($r.Edition -like 'Express*' -and $r.DataMB -ge 8192) { $warn += ('⚠ Data file is {0} - SQL Express stops at 10 GB.' -f (Format-Size $r.DataMB)) }
    $txtSqlFileWarn.Text = $warn -join "`r`n"
    $txtSqlFileWarn.Visibility = if ($warn.Count -gt 0) { 'Visible' } else { 'Collapsed' }

    # SQL Server
    $txtSqlEdition.Text = ("{0}  {1}" -f $r.Friendly, $r.Edition).Trim()
    $txtSqlBuild.Text   = ((@($r.ProductVersion, $r.Level, $r.UpdateLevel) | Where-Object { $_ }) -join ' · ') + "   ($($r.ServerName))"
    $txtSqlUptime.Text  = if ($r.StartTime) { 'Running since {0}  ({1})' -f ([datetime]$r.StartTime).ToString('yyyy-MM-dd HH:mm'), ((Format-Age $r.StartTime) -replace ' ago$', '') } else { '' }

    $msg = "Read from $($script:GuruSqlServer) at $when."
    if (@($r.Notes).Count -gt 0) { $msg += '  ' + (@($r.Notes) -join '  '); Set-SqlStatus $msg '#F9E2AF' } else { Set-SqlStatus $msg '#A6E3A1' }
}
function Get-SqlTabText {
    $r = $script:SqlInfo
    if (-not $r) { return 'SQL: not checked yet' }
    if (-not $r.Ok) { return "SQL: could not read $($script:GuruSqlServer) - $($r.Error)" }
    @(
        "Server:                $env:COMPUTERNAME",
        "Database:              $($r.Database) on $($script:GuruSqlServer)",
        "Database full version: $($txtSqlDbFull.Text)",
        "Last full backup:      $($txtBkFull.Text)",
        "Last differential:     $($txtBkDiff.Text)",
        "Last log backup:       $($txtBkLog.Text)",
        "Last backup saved to:  $($r.LastPath)",
        "Default backup folder: $($txtBkDefault.Text)",
        "Log file:              $($txtSqlLogSize.Text)  $($txtSqlLogUsed.Text)",
        "Data file:             $($txtSqlDataSize.Text)  $($txtSqlDataUsed.Text)",
        "Recovery model:        $($txtSqlRecovery.Text)",
        "SQL Server:            $($txtSqlEdition.Text)  $($txtSqlBuild.Text)"
    ) -join "`r`n"
}
$btnSqlRefresh.Add_Click({ Start-SqlCheck })
$btnSqlCopy.Add_Click({
    try { [System.Windows.Clipboard]::SetText((Get-SqlTabText)); Set-SqlStatus 'SQL details copied to clipboard.' '#A6E3A1' }
    catch { Set-SqlStatus "Copy failed: $($_.Exception.Message)" '#F38BA8' }
})
$btnBkOpenLast.Add_Click({    if ($script:SqlInfo) { Open-SqlFolder ([string]$script:SqlInfo.LastPath) $true } })
$btnBkOpenDefault.Add_Click({ if ($script:SqlInfo) { Open-SqlFolder ([string]$script:SqlInfo.DefaultPath) $false } })
$MainTabs.Add_SelectionChanged({
    # only react to the main tabs (inner tab controls and grids raise this event too)
    if ($_.OriginalSource -ne $MainTabs) { return }
    if ($tabSql.IsSelected -and -not $script:SqlJob -and ((Get-Date) - $script:LastSqlCheck).TotalSeconds -ge 60) { Start-SqlCheck }
    if ($tabReaders.IsSelected -and -not $script:ReaderJob -and ((Get-Date) - $script:LastReaderLoad).TotalSeconds -ge 60) { Start-ReaderLoad }
})
# ------------------------------------------------------------
# READERS TAB (swiper units + reader units) - read-only
# Swiper_Units -> Game_Swipers (Game_Id) -> Game_Master_List (Game_ML_Id) for the game name.
# Reader_Units is matched to its swiper unit by Swiper_Id + Location_Id.
# Reader type: STP when Reader_Units.STP_Software_Hash has a value, otherwise STS.
# ------------------------------------------------------------
$script:ReaderScript = {
    param($sqlServer, $knownDb)
    $o = [ordered]@{ Ok = $false; Error = ''; Database = ''; Swipers = @(); Readers = @() }
    function Get-Deepest($err) { $e = $err.Exception; while ($e.InnerException) { $e = $e.InnerException }; $e.Message }
    function New-Conn([string]$db) {
        $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $b['Data Source']            = $sqlServer
        $b['Initial Catalog']        = $db
        $b['Integrated Security']    = $true
        $b['TrustServerCertificate'] = $true
        $b['Connect Timeout']        = 5
        $b['Application Name']       = "EMBED Services Dashboard $($script:AppVersion)"
        New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
    }
    function Get-Rows($conn, [string]$sql) {
        $cmd = $conn.CreateCommand(); $cmd.CommandTimeout = 30; $cmd.CommandText = $sql
        $dt = New-Object System.Data.DataTable
        $dt.Load($cmd.ExecuteReader())
        foreach ($r in $dt.Rows) {
            $h = [ordered]@{}
            foreach ($c in $dt.Columns) { $v = $r[$c]; if ($v -is [DBNull]) { $v = $null }; $h[$c.ColumnName] = $v }
            [PSCustomObject]$h
        }
    }
    $swiperSql = @"
SELECT su.Swiper_Id, su.Location_Id, RTRIM(su.Game_Id) AS Game_Id, RTRIM(su.Polling_Group) AS Polling_Group,
       CAST(su.Status AS int) AS Status, CAST(su.Paused AS int) AS Paused, su.LastComms,
       RTRIM(gs.Swiper_Description) AS Swiper_Description, gs.Retired AS Swiper_Retired,
       RTRIM(gml.Game_Name) AS Game_Name, gml.Retired AS Game_Retired
FROM dbo.Swiper_Units su
OUTER APPLY (SELECT TOP 1 g.* FROM dbo.Game_Swipers g
             WHERE g.Game_Id = su.Game_Id
             ORDER BY CASE WHEN g.Location_Id = su.Location_Id THEN 0 ELSE 1 END) gs
LEFT JOIN dbo.Game_Master_List gml ON gml.Game_ML_Id = gs.Game_ML_Id
"@
    $readerSql = @"
SELECT RTRIM(Reader_Id) AS Reader_Id, Swiper_Id, Location_Id, RTRIM(IPAddress) AS IPAddress,
       RTRIM(Media_Version) AS Media_Version,
       CASE WHEN NULLIF(LTRIM(RTRIM(STP_Software_Hash)), '') IS NULL THEN 'STS' ELSE 'STP' END AS ReaderType
FROM dbo.Reader_Units
"@
    $cn = $null
    try {
        $cn = New-Conn 'master'
        $cn.Open()
        $dbs = @(Get-Rows $cn 'SELECT name FROM sys.databases WHERE database_id > 4 AND state = 0 ORDER BY name' | ForEach-Object { [string]$_.name })
        $cn.Dispose(); $cn = $null
        $order = @(); if ($knownDb -and ($dbs -contains $knownDb)) { $order += $knownDb }; $order += @($dbs | Where-Object { $_ -ne $knownDb })
        foreach ($db in $order) {
            $c = New-Conn $db
            try {
                $c.Open()
                $chk = @(Get-Rows $c "SELECT OBJECT_ID('dbo.Swiper_Units') AS S, OBJECT_ID('dbo.Reader_Units') AS R, OBJECT_ID('dbo.Game_Swipers') AS G, OBJECT_ID('dbo.Game_Master_List') AS M")[0]
                if (-not $chk.S -or -not $chk.R -or -not $chk.G -or -not $chk.M) { continue }
                $o.Database = $db
                $o.Swipers  = @(Get-Rows $c $swiperSql)
                $o.Readers  = @(Get-Rows $c $readerSql)
                break
            } catch {
                if ($o.Database) { throw }            # found the right database but the query failed - report it
            } finally { $c.Dispose() }
        }
        if (-not $o.Database) { throw 'No database with Swiper_Units, Reader_Units, Game_Swipers and Game_Master_List was found.' }
        $o.Ok = $true
    } catch {
        $o.Error = Get-Deepest $_
    } finally { if ($cn) { $cn.Dispose() } }
    [PSCustomObject]$o
}
$script:ReaderJob     = $null
$script:ReaderRows    = @()
$script:ReaderInfo    = $null
$script:LastReaderLoad = [datetime]::MinValue
$script:ReaderType    = 'All'
$script:ReaderList    = New-Object System.Collections.ObjectModel.ObservableCollection[PSObject]
$dgReaders.ItemsSource = $script:ReaderList
function Set-RdStatus([string]$text, [string]$hex) { $txtRdStatus.Text = $text; $txtRdStatus.Foreground = ColorBrush $hex }
function Start-ReaderLoad {
    if ($script:ReaderJob) { return }
    $script:LastReaderLoad = Get-Date
    $known = ''
    if ($script:SqlInfo -and $script:SqlInfo.Ok -and $script:SqlInfo.PSObject.Properties['Database']) { $known = [string]$script:SqlInfo.Database }
    elseif ($script:DbVer -and $script:DbVer.Ok -and $script:DbVer.PSObject.Properties['Database']) { $known = [string]$script:DbVer.Database }
    try {
        $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($script:ReaderScript.ToString()).AddArgument([string]$script:GuruSqlServer).AddArgument($known)
        $script:ReaderJob = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
        $btnRdRefresh.IsEnabled = $false
        Set-RdStatus "Reading units from $($script:GuruSqlServer)..." '#89B4FA'
    } catch {
        $script:ReaderJob = $null
        $btnRdRefresh.IsEnabled = $true
        Set-RdStatus "Could not start: $($_.Exception.Message)" '#F38BA8'
    }
}
function Complete-ReaderLoad {
    $job = $script:ReaderJob
    $script:ReaderJob = $null
    $btnRdRefresh.IsEnabled = $true
    $r = $null
    try     { $r = @($job.PS.EndInvoke($job.Handle)) | Select-Object -Last 1 }
    catch   { $r = [PSCustomObject]@{ Ok = $false; Error = $_.Exception.Message } }
    finally { try { $job.PS.Dispose(); $job.RS.Close(); $job.RS.Dispose() } catch {} }
    if (-not $r) { $r = [PSCustomObject]@{ Ok = $false; Error = 'The query returned nothing.' } }
    $script:ReaderInfo = $r
    if (-not $r.Ok) { Set-RdStatus "Could not read units from $($script:GuruSqlServer): $($r.Error)" '#F38BA8'; return }

    # Readers by swiper (Swiper_Id + Location_Id)
    $rdBySwiper = @{}
    foreach ($rd in @($r.Readers)) { $rdBySwiper["$($rd.Swiper_Id)|$($rd.Location_Id)"] = $rd }
    $used = @{}
    $rows = @()
    foreach ($s in @($r.Swipers)) {
        $key = "$($s.Swiper_Id)|$($s.Location_Id)"
        $rd  = $rdBySwiper[$key]; if ($rd) { $used[$key] = $true }
        $retired = ($null -ne $s.Swiper_Retired) -or ($null -ne $s.Game_Retired)
        $rows += [PSCustomObject]@{
            Type        = $(if ($rd) { [string]$rd.ReaderType } else { '—' })
            GameName    = [string]$s.Game_Name
            Description = [string]$s.Swiper_Description
            GameId      = [string]$s.Game_Id
            SwiperId    = [string]$s.Swiper_Id
            ReaderId    = $(if ($rd) { [string]$rd.Reader_Id } else { '' })
            Ip          = $(if ($rd) { [string]$rd.IPAddress } else { '' })
            PollGroup   = [string]$s.Polling_Group
            Paused      = $(if ([int]$s.Paused -eq 1) { 'Yes' } else { 'No' })
            Status      = [string]$s.Status
            LastComms   = $(if ($s.LastComms) { ([datetime]$s.LastComms).ToString('yyyy-MM-dd HH:mm') } else { '' })
            MediaVer    = $(if ($rd) { [string]$rd.Media_Version } else { '' })
            Retired     = $retired
            IsSwiper    = $true
        }
    }
    # Readers that are not attached to any swiper unit still show up
    foreach ($rd in @($r.Readers)) {
        if ($used.ContainsKey("$($rd.Swiper_Id)|$($rd.Location_Id)")) { continue }
        $rows += [PSCustomObject]@{
            Type = [string]$rd.ReaderType; GameName = '(no swiper unit)'; Description = ''; GameId = ''
            SwiperId = [string]$rd.Swiper_Id; ReaderId = [string]$rd.Reader_Id; Ip = [string]$rd.IPAddress
            PollGroup = ''; Paused = ''; Status = ''; LastComms = ''; MediaVer = [string]$rd.Media_Version
            Retired = $false; IsSwiper = $false
        }
    }
    $script:ReaderRows = @($rows | Sort-Object GameName, Description)

    # Hard counts (retired swiper units left out)
    $active   = @($rows | Where-Object { $_.IsSwiper -and -not $_.Retired })
    $retiredN = @($rows | Where-Object { $_.IsSwiper -and $_.Retired }).Count
    $readers  = @($r.Readers)
    $txtRdSwipers.Text    = [string]$active.Count
    $txtRdSwipersSub.Text = if ($retiredN -gt 0) { "active  ($retiredN retired not counted)" } else { 'active' }
    $txtRdReaders.Text    = [string]$readers.Count
    $noSwiper = @($rows | Where-Object { -not $_.IsSwiper }).Count
    $txtRdReadersSub.Text = if ($noSwiper -gt 0) { "$noSwiper not linked to a swiper unit" } else { 'all linked to a swiper unit' }
    $txtRdSts.Text    = [string]@($readers | Where-Object { $_.ReaderType -eq 'STS' }).Count
    $txtRdStp.Text    = [string]@($readers | Where-Object { $_.ReaderType -eq 'STP' }).Count
    $txtRdPaused.Text = [string]@($active | Where-Object { $_.Paused -eq 'Yes' }).Count

    Update-ReaderList
    Set-RdStatus ("Loaded from {0} on {1} at {2}." -f $r.Database, $script:GuruSqlServer, (Get-Date).ToString('HH:mm:ss')) '#A6E3A1'
}
function Update-ReaderList {
    $q   = $txtRdSearch.Text.Trim()
    $ret = [bool]$chkRdRetired.IsChecked
    $script:ReaderList.Clear()
    foreach ($x in $script:ReaderRows) {
        if ($x.Retired -and -not $ret) { continue }
        if ($script:ReaderType -ne 'All' -and $x.Type -ne $script:ReaderType) { continue }
        if ($q) {
            $hay = "$($x.GameName) $($x.Description) $($x.GameId) $($x.SwiperId) $($x.ReaderId) $($x.Ip)"
            if ($hay.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        }
        $script:ReaderList.Add($x)
    }
    $txtRdCount.Text = "$($script:ReaderList.Count) shown of $(@($script:ReaderRows).Count)"
}
function Set-ReaderType([string]$t) {
    $script:ReaderType = $t
    foreach ($p in @(@($btnRdAll, 'All'), @($btnRdSts, 'STS'), @($btnRdStp, 'STP'))) {
        $p[0].Style = $window.FindResource($(if ($p[1] -eq $t) { 'BtnPurple' } else { 'BtnBase' }))
    }
    Update-ReaderList
}
function Get-ReaderTabText {
    $r = $script:ReaderInfo
    if (-not $r -or -not $r.Ok) { return 'Readers: not loaded' }
    $lines = @(
        "Server: $env:COMPUTERNAME   Database: $($r.Database) on $($script:GuruSqlServer)",
        "Swiper units: $($txtRdSwipers.Text) ($($txtRdSwipersSub.Text))   Reader units: $($txtRdReaders.Text)   STS: $($txtRdSts.Text)   STP: $($txtRdStp.Text)   Paused: $($txtRdPaused.Text)",
        "",
        (@('Type','Game name','Description','Game Id','Swiper','Reader Id','IP','Poll grp','Paused','Status','Last comms','Media ver.') -join "`t")
    )
    foreach ($x in $script:ReaderList) {
        $lines += (@($x.Type, $x.GameName, $x.Description, $x.GameId, $x.SwiperId, $x.ReaderId, $x.Ip, $x.PollGroup, $x.Paused, $x.Status, $x.LastComms, $x.MediaVer) -join "`t")
    }
    $lines -join "`r`n"
}
$btnRdRefresh.Add_Click({ Start-ReaderLoad })
$btnRdCopy.Add_Click({
    try { [System.Windows.Clipboard]::SetText((Get-ReaderTabText)); Set-RdStatus 'Counts and list copied to clipboard (pastes into Excel).' '#A6E3A1' }
    catch { Set-RdStatus "Copy failed: $($_.Exception.Message)" '#F38BA8' }
})
$txtRdSearch.Add_TextChanged({ Update-ReaderList })
$chkRdRetired.Add_Click({ Update-ReaderList })
$btnRdAll.Add_Click({ Set-ReaderType 'All' })
$btnRdSts.Add_Click({ Set-ReaderType 'STS' })
$btnRdStp.Add_Click({ Set-ReaderType 'STP' })
# ------------------------------------------------------------
# TIMER
# ------------------------------------------------------------
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromSeconds(1)
$script:Timer.Add_Tick({
    if ($script:DeviceScan -and $script:DeviceScan.Handle.IsCompleted) { Complete-DeviceScan }
    if ($script:DiscoverScan -and $script:DiscoverScan.Handle.IsCompleted) { Complete-DiscoverScan }
    if ($script:UpdateScan -and $script:UpdateScan.Handle.IsCompleted) { Complete-UpdateCheck }
    if ($script:SnapshotJob -and $script:SnapshotJob.Handle.IsCompleted) { Complete-Snapshot }
    if ($script:RemoteJob   -and $script:RemoteJob.Handle.IsCompleted)   { Complete-RemoteJob }
    if ($script:DbVerJob    -and $script:DbVerJob.Handle.IsCompleted)    { Complete-DbVersionCheck }
    if ($script:SqlJob      -and $script:SqlJob.Handle.IsCompleted)      { Complete-SqlCheck }
    if ($script:ReaderJob   -and $script:ReaderJob.Handle.IsCompleted)   { Complete-ReaderLoad }
    $swLine = $null; $swAny = $false
    while ($script:SwLog.TryDequeue([ref]$swLine)) { $txtSwLog.AppendText($swLine + "`r`n"); $swAny = $true }
    if ($swAny) { $txtSwLog.ScrollToEnd() }
    if ($script:SwJob       -and $script:SwJob.Handle.IsCompleted)       { Complete-SoftwareJob }
    if ((-not $script:DbVerJob) -and (((Get-Date) - $script:LastDbVerCheck).TotalMinutes -ge $script:DbVerMinutes)) { Start-DbVersionCheck }
    if ((-not $script:SqlJob) -and (((Get-Date) - $script:LastSqlCheck).TotalHours -ge $script:SqlCheckHours)) { Start-SqlCheck }
    if ((-not $script:UpdateScan) -and $script:UpdateConfig['AutoCheck'] -and ([string]$script:UpdateConfig['Repo']) -and (((Get-Date) - $script:LastUpdateCheck).TotalHours -ge 6)) {
        Start-UpdateCheck ([bool]$script:UpdateConfig['AutoInstall'])
    }
    $script:CountdownSecs--
    if ($script:CountdownSecs -le 0) {
        $script:CountdownSecs = $script:RefreshSecs
        Set-StatusColor 'Updating'
        Set-TrayIconColor 'Updating'
        $statusBar.Text = "Refreshing services..."
        Update-AllServices
    }
    $script:DeviceCountdown--
    if ($script:DeviceCountdown -le 0) {
        $script:DeviceCountdown = $script:DeviceSecs
        [void](Start-DeviceScan)
    }
    if ($statStopped.Text -ne '0') {
        Set-StatusColor 'Warning'
        Set-TrayIconColor 'Warning'
    }
    elseif ($statOther.Text -ne '0') {
        Set-StatusColor 'Error'
        Set-TrayIconColor 'Error'
    }
    else {
        Set-StatusColor 'Healthy'
        Set-TrayIconColor 'Healthy'
    }
    $txtCountdown.Text = Format-Countdown $script:CountdownSecs
})
# ------------------------------------------------------------
# INITIALIZE UI
# ------------------------------------------------------------
Build-ServiceRows
Apply-Filter 'All'
Update-AllServices
[void](Start-DeviceScan)
Set-StatusColor 'Healthy'
Set-TrayIconColor 'Healthy'
$statusBar.Text       = "Dashboard ready."
$statusBarRight.Text  = "Last scan: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
Initialize-SnapshotUi
Initialize-TimerUi
Start-DbVersionCheck
[void](Remove-OldSnapshots)
Remove-OldHistoryLogs
$script:Timer.Start()
# ------------------------------------------------------------
# SHOW WINDOW
# ------------------------------------------------------------
$window.ShowDialog() | Out-Null
