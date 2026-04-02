# network_switch.ps1 — GUI скрипт для управления профилями сетевого адаптера.

# === Повышение прав ===
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )) {
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Add-Type -AssemblyName PresentationFramework

# =========================================================
# ===             Конфигурации профилей              ===
# =========================================================
$NetworkConfigs = [ordered]@{
    "Config 1" = @{
        Name           = "Config 1"
        Mode           = "Static"   # Static | DHCP
        IPAddress      = "192.168.1.2"
        PrefixLength   = 24
        DefaultGateway = "192.168.1.1"
        DNS            = @("8.8.8.8", "8.8.4.4")
        ProxyEnabled   = $false
        Description    = "Config 1 no proxy"
    }

    "Config 2" = @{
        Name           = "Config 2"
        Mode           = "Static"
        IPAddress      = "192.168.1.3"
        PrefixLength   = 24
        DefaultGateway = "192.168.1.1"
        DNS            = @("8.8.8.8", "8.8.4.4")
        ProxyEnabled   = $true
        ProxyServer    = "192.168.1.1:3128"
        ProxyOverride  = "<local>"
        Description    = "Config 2 with proxy"
    }

    "DHCP"     = @{
        Name         = "DHCP"
        Mode         = "DHCP"
        ProxyEnabled = $false
        Description  = "Автоматическое получение IP и DNS"
    }
}

# ==================================
# === Вспомогательные функции ======
# ==================================

function Test-IsNullOrWhiteSpace([object]$Value) {
    return [string]::IsNullOrWhiteSpace([string]$Value)
}

function Get-ProfileMode($cfg) {
    if ($cfg.ContainsKey('Mode') -and -not (Test-IsNullOrWhiteSpace $cfg.Mode)) {
        return [string]$cfg.Mode
    }

    if ($cfg.ContainsKey('IPAddress') -and -not (Test-IsNullOrWhiteSpace $cfg.IPAddress)) {
        return "Static"
    }

    return "DHCP"
}

function Format-ProfileText($cfg) {
    $mode = Get-ProfileMode $cfg

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Профиль: $($cfg.Name)")

    if ($cfg.Description) {
        $lines.Add("Описание: $($cfg.Description)")
    }

    $lines.Add("Режим: $mode")

    if ($mode -eq "Static") {
        if ($cfg.IPAddress) { $lines.Add("IP: $($cfg.IPAddress)/$($cfg.PrefixLength)") }
        if ($cfg.DefaultGateway) { $lines.Add("Шлюз: $($cfg.DefaultGateway)") }
        if ($cfg.DNS -and $cfg.DNS.Count -gt 0) {
            $lines.Add("DNS: $([string]::Join(', ', $cfg.DNS))")
        }
    }
    else {
        $lines.Add("IP/DNS: автоматически (DHCP)")
    }

    if ($cfg.ProxyEnabled) {
        $proxyText = if ($cfg.ProxyServer) { $cfg.ProxyServer } else { "включен" }
        $lines.Add("Прокси: $proxyText")
        if ($cfg.ProxyOverride) {
            $lines.Add("Исключения: $($cfg.ProxyOverride)")
        }
    }
    else {
        $lines.Add("Прокси: отключен")
    }

    return ($lines -join [Environment]::NewLine)
}

function Get-PrimaryIPv4Address([string]$AdapterName) {
    Get-NetIPAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.IPAddress -notlike '169.254.*' -and
        $_.PrefixOrigin -ne 'WellKnown'
    } |
    Sort-Object SkipAsSource, IPAddress |
    Select-Object -First 1
}

function Get-AdapterConfig([string]$AdapterName) {
    try {
        if (Test-IsNullOrWhiteSpace $AdapterName) {
            return "Адаптер не выбран"
        }

        $ipAll = Get-NetIPAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' }

        $dns = Get-DnsClientServerAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $gw = (Get-NetRoute -InterfaceAlias $AdapterName -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1).NextHop

        $dhcpState = (Get-NetIPInterface -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp

        $ips = @()
        foreach ($ip in $ipAll) {
            $ips += "$($ip.IPAddress)/$($ip.PrefixLength)"
        }

        $proxyEnable = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue).ProxyEnable
        $proxyServer = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue).ProxyServer

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("Адаптер: $AdapterName")
        $lines.Add("DHCP: $dhcpState")

        if ($ips.Count -gt 0) {
            $lines.Add("IP-адреса: $([string]::Join(', ', $ips))")
        }
        else {
            $lines.Add("IP-адреса: отсутствуют")
        }

        $lines.Add("Шлюз: $(if ($gw) { $gw } else { 'не задан' })")

        if ($dns -and $dns.ServerAddresses -and $dns.ServerAddresses.Count -gt 0) {
            $lines.Add("DNS: $([string]::Join(', ', $dns.ServerAddresses))")
        }
        else {
            $lines.Add("DNS: автоматически или не заданы")
        }

        if ($proxyEnable -eq 1) {
            $lines.Add("Прокси: включен ($proxyServer)")
        }
        else {
            $lines.Add("Прокси: отключен")
        }

        return ($lines -join [Environment]::NewLine)
    }
    catch {
        return "Не удалось получить конфигурацию адаптера '$AdapterName': $($_.Exception.Message)"
    }
}

function Clear-IPv4Config([string]$AdapterName) {
    $existingIPs = Get-NetIPAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.PrefixOrigin -ne 'WellKnown' }

    foreach ($ip in $existingIPs) {
        try {
            Remove-NetIPAddress -InputObject $ip -Confirm:$false -ErrorAction SilentlyContinue
        }
        catch {}
    }

    Get-NetRoute -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } |
    ForEach-Object {
        try {
            Remove-NetRoute -InputObject $_ -Confirm:$false -ErrorAction SilentlyContinue
        }
        catch {}
    }

    Start-Sleep -Milliseconds 400
}

function Set-ProxyConfig($cfg) {
    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

    if ($cfg.ProxyEnabled) {
        Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 1
        Set-ItemProperty -Path $regPath -Name ProxyServer -Value $cfg.ProxyServer

        if ($cfg.ProxyOverride) {
            Set-ItemProperty -Path $regPath -Name ProxyOverride -Value $cfg.ProxyOverride
        }
        else {
            Remove-ItemProperty -Path $regPath -Name ProxyOverride -ErrorAction SilentlyContinue
        }
    }
    else {
        Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0
        Remove-ItemProperty -Path $regPath -Name ProxyServer -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $regPath -Name ProxyOverride -ErrorAction SilentlyContinue
    }

    # Попытка уведомить систему о смене настроек
    try {
        $signature = @"
using System;
using System.Runtime.InteropServices;
public class WinInetRefresh {
    [DllImport("wininet.dll", SetLastError=true)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
"@
        Add-Type -TypeDefinition $signature -ErrorAction SilentlyContinue | Out-Null
        [WinInetRefresh]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
        [WinInetRefresh]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
    }
    catch {}
}

function Validate-ProfileConfig($cfg) {
    $mode = Get-ProfileMode $cfg

    if ($mode -eq 'Static') {
        foreach ($required in @('IPAddress', 'PrefixLength')) {
            if (-not $cfg.ContainsKey($required) -or (Test-IsNullOrWhiteSpace $cfg[$required])) {
                throw "В профиле '$($cfg.Name)' отсутствует обязательный параметр '$required'."
            }
        }
    }

    if ($cfg.ProxyEnabled -and (Test-IsNullOrWhiteSpace $cfg.ProxyServer)) {
        throw "В профиле '$($cfg.Name)' включен прокси, но не задан ProxyServer."
    }
}

function Apply-Config([string]$AdapterName, $cfg, $onDone) {
    try {
        if (Test-IsNullOrWhiteSpace $AdapterName) {
            throw "Не выбран сетевой адаптер."
        }

        Validate-ProfileConfig $cfg
        $mode = Get-ProfileMode $cfg

        Clear-IPv4Config $AdapterName

        if ($mode -eq 'Static') {
            Set-NetIPInterface -InterfaceAlias $AdapterName -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue

            $newIpParams = @{
                InterfaceAlias = $AdapterName
                IPAddress      = $cfg.IPAddress
                PrefixLength   = [int]$cfg.PrefixLength
                AddressFamily  = 'IPv4'
                ErrorAction    = 'Stop'
            }

            if (-not (Test-IsNullOrWhiteSpace $cfg.DefaultGateway)) {
                $newIpParams['DefaultGateway'] = $cfg.DefaultGateway
            }

            New-NetIPAddress @newIpParams | Out-Null

            if ($cfg.DNS -and $cfg.DNS.Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceAlias $AdapterName -ServerAddresses $cfg.DNS -ErrorAction Stop
            }
            else {
                Set-DnsClientServerAddress -InterfaceAlias $AdapterName -ResetServerAddresses -ErrorAction Stop
            }
        }
        else {
            Set-NetIPInterface -InterfaceAlias $AdapterName -AddressFamily IPv4 -Dhcp Enabled -ErrorAction Stop
            Set-DnsClientServerAddress -InterfaceAlias $AdapterName -ResetServerAddresses -ErrorAction Stop

            Start-Sleep -Seconds 1
            ipconfig /renew | Out-Null
        }

        Set-ProxyConfig $cfg

        & $onDone $true "Профиль '$($cfg.Name)' применён."
    }
    catch {
        & $onDone $false "Ошибка при применении профиля '$($cfg.Name)': $($_.Exception.Message)"
    }
}

# =====================
# === XAML интерфейс ===
# =====================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Network Switcher GUI"
        Height="620" Width="760"
        MinHeight="620" MinWidth="760"
        WindowStartupLocation="CenterScreen">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="2*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="2*"/>
    </Grid.RowDefinitions>

    <TextBlock Text="Выберите сетевой адаптер:" FontSize="14" FontWeight="Bold"/>
    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,6,0,10">
      <ComboBox Name="AdapterBox" Width="420" Height="28" Margin="0,0,8,0"/>
      <Button Name="BtnRefresh" Content="Обновить" Width="110" Height="28"/>
    </StackPanel>

    <GroupBox Header="Текущая конфигурация" Grid.Row="2" Margin="0,0,0,10">
      <TextBox Name="OutputBox" Margin="8"
               IsReadOnly="True"
               TextWrapping="Wrap"
               VerticalScrollBarVisibility="Auto"
               AcceptsReturn="True"/>
    </GroupBox>

    <TextBlock Grid.Row="3" Text="Профили" FontSize="14" FontWeight="Bold" Margin="0,0,0,6"/>

    <ScrollViewer Grid.Row="4" VerticalScrollBarVisibility="Disabled" HorizontalScrollBarVisibility="Auto" Margin="0,0,0,10">
      <WrapPanel Name="ProfilesPanel"/>
    </ScrollViewer>

    <GroupBox Header="Параметры профиля" Grid.Row="5">
      <TextBox Name="ProfileBox" Margin="8"
               IsReadOnly="True"
               TextWrapping="Wrap"
               VerticalScrollBarVisibility="Auto"
               AcceptsReturn="True"/>
    </GroupBox>
  </Grid>
</Window>
"@

# =========================
# === Создание окна =======
# =========================
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# === Элементы ===
$cbAdapter = $window.FindName('AdapterBox')
$btnRefresh = $window.FindName('BtnRefresh')
$txtOut = $window.FindName('OutputBox')
$txtProfile = $window.FindName('ProfileBox')
$profilesPanel = $window.FindName('ProfilesPanel')

# =================================
# === Загрузка и обновление UI ====
# =================================
function Load-Adapters {
    $cbAdapter.Items.Clear()

    $allAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object Name)
    $activeAdapters = @($allAdapters | Where-Object Status -eq 'Up')

    $list = if ($activeAdapters.Count -gt 0) { $activeAdapters } else { $allAdapters }

    foreach ($a in $list) {
        [void]$cbAdapter.Items.Add($a.Name)
    }

    if ($cbAdapter.Items.Count -gt 0 -and $null -eq $cbAdapter.SelectedItem) {
        $cbAdapter.SelectedIndex = 0
    }
}

$updateConfig = {
    if ($null -ne $cbAdapter.SelectedItem) {
        $txtOut.Text = Get-AdapterConfig ([string]$cbAdapter.SelectedItem)
    }
    else {
        $txtOut.Text = "Адаптер не выбран"
    }
}

$showProfile = {
    param($cfgKey)
    $txtProfile.Text = Format-ProfileText $NetworkConfigs[$cfgKey]
}

$onApplied = {
    param([bool]$ok, [string]$msg)

    if ($ok) {
        [System.Windows.MessageBox]::Show($msg, "Готово") | Out-Null
    }
    else {
        [System.Windows.MessageBox]::Show($msg, "Ошибка") | Out-Null
    }

    & $updateConfig
}

function Add-ProfileButtons {
    $profilesPanel.Children.Clear()

    foreach ($cfgKey in $NetworkConfigs.Keys) {
        $cfg = $NetworkConfigs[$cfgKey]

        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $cfg.Name
        $btn.Width = 130
        $btn.Height = 38
        $btn.Margin = '4'
        $btn.ToolTip = Format-ProfileText $cfg
        $btn.Tag = $cfgKey

        $btn.Add_MouseEnter({
                $key = [string]$this.Tag
                & $showProfile $key
            })

        $btn.Add_Click({
                if ($null -eq $cbAdapter.SelectedItem) {
                    [System.Windows.MessageBox]::Show("Сначала выберите сетевой адаптер.", "Внимание") | Out-Null
                    return
                }

                $key = [string]$this.Tag
                Apply-Config ([string]$cbAdapter.SelectedItem) $NetworkConfigs[$key] $onApplied
            })

        [void]$profilesPanel.Children.Add($btn)
    }
}

# ==========================
# === События интерфейса ===
# ==========================
$cbAdapter.Add_SelectionChanged($updateConfig)
$btnRefresh.Add_Click({
        Load-Adapters
        & $updateConfig
    })

# ==========================
# === Первичная загрузка ===
# ==========================
Load-Adapters
Add-ProfileButtons
& $updateConfig

if ($NetworkConfigs.Count -gt 0) {
    $firstKey = @($NetworkConfigs.Keys)[0]
    $txtProfile.Text = Format-ProfileText $NetworkConfigs[$firstKey]
}
else {
    $txtProfile.Text = "Профили не настроены"
}

# === Запуск окна ===
[void]$window.ShowDialog()