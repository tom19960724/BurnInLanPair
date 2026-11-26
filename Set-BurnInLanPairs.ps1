#Requires -Version 5.1
<#
.SYNOPSIS
  同一台電腦、網路線把埠兩兩對接時，自動配對、設定靜態 IP，並寫出 BurnInTest 目的位址腳本。

.DESCRIPTION
  BurnInTest 標準網路測試是 ICMP ping。
  測試模式選「所有實體網卡」時，第 1 列目的位址綁到系統列出的第 1 張已連線實體網卡，
  第 2 列綁到第 2 張，依此類推。每一列要填的是「同一條線另一端」的 IP，不是自己的 IP。

  這個腳本會：
  1. 略過有預設閘道的網卡（避免改到正在上網的那張）。
  不論怎麼插／拔，按「設定與配對」都要跑完：
  - 先設正式 IP（192.168.1.<Ethernet編號>）。
  - 配對用雙向硬體收包判定「同一條線」兩端（雙向都要收到才算成對），結果給 BurnInTest。
  - 沒有成對的線 → 只設 IP（IpOnly），不是錯誤。
  - MAC 重複時改寫第 2 張起的 LAA。

.PARAMETER List
  只列出會被拿來配對的網卡，不改 IP。

.PARAMETER Restore
  用同目錄的 ip-backup.json 還原這個腳本改過的位址。
#>
param(
    [ValidateSet('Setup', 'WriteBurnIn', 'Full', 'List', 'Restore')]
    [string]$Action = 'Full',
    [switch]$SkipCpu,
    [switch]$SkipMemory,
    [switch]$List,
    [switch]$Restore
)

if ($List) { $Action = 'List' }
if ($Restore) { $Action = 'Restore' }
$Restore = $Action -eq 'Restore'
$List = $Action -eq 'List'

function Write-UiProgress {
    param([int]$Percent, [string]$Message = '')
    # 直接寫 stdout，不進函式回傳值；否則在 $x = Get-CablePairs 這類呼叫裡會把結果物件污染成陣列
    [Console]::Out.WriteLine(("PROGRESS|{0}|{1}" -f [Math]::Max(0, [Math]::Min(100, $Percent)), $Message))
    [Console]::Out.Flush()
}

$ErrorActionPreference = 'Stop'
try {
    chcp 65001 > $null
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
} catch {}

function Get-AppPath {
    return [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}

function Test-RunningAsExe {
    if ($env:BURNIN_LAN_HOME) { return $true }
    $path = Get-AppPath
    return ($path -match '\.exe$') -and ($path -notmatch '\\powershell\.exe$') -and ($path -notmatch '\\pwsh\.exe$')
}

function Save-ErrorLog {
    param([string]$Text)
    $path = Join-Path $OutputDir 'burnin-lan-error.txt'
    try {
        Set-Content -LiteralPath $path -Value $Text -Encoding UTF8
        Write-Host "錯誤檔：$path"
    } catch {}
}

function Wait-Exit {
    if ($env:BURNIN_LAN_NO_PAUSE -eq '1') { return }
    Write-Host ''
    Write-Host '按 Enter 關閉視窗。'
    try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 30 }
}

if ($env:BURNIN_LAN_HOME) {
    $OutputDir = $env:BURNIN_LAN_HOME
} elseif (Test-RunningAsExe) {
    $OutputDir = Split-Path -Parent (Get-AppPath)
} elseif ($PSScriptRoot) {
    $OutputDir = $PSScriptRoot
} else {
    $OutputDir = (Get-Location).Path
}
$BackupPath = Join-Path $OutputDir 'ip-backup.json'
$BitsPath = Join-Path $OutputDir 'lan-pairs.bits'
$ReportPath = Join-Path $OutputDir 'lan-pairs.txt'
$StatePath = Join-Path $OutputDir 'lan-pair-state.json'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $List -and -not (Test-IsAdmin)) {
    if (Test-RunningAsExe) {
        $argList = @()
        if ($Restore) { $argList += '-Restore' }
        elseif ($Action -and $Action -ne 'Full') { $argList += @('-Action', $Action) }
        foreach ($key in 'SkipCpu','SkipMemory') { if ($PSBoundParameters[$key]) { $argList += "-$key" } }
        Start-Process -FilePath (Get-AppPath) -Verb RunAs -ArgumentList $argList | Out-Null
    } else {
        $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($Restore) { $arg += ' -Restore' }
        elseif ($Action -and $Action -ne 'Full') { $arg += " -Action $Action" }
        foreach ($key in 'SkipCpu','SkipMemory') { if ($PSBoundParameters[$key]) { $arg += " -$key" } }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arg | Out-Null
    }
    Write-Host '已要求系統管理員權限，請在跳出的視窗確認。'
    return
}

function Test-AdapterHasLink {
    param($Adapter)
    if (-not $Adapter) { return $false }
    # 以 Status=Up 為主。Intel 雙埠在拔線後偶數埠常被標成 Disconnected 但其實對端還在，
    # 若只信 MediaConnectionState 會變成只剩 1/3/5/7，對接必錯。
    if ([string]$Adapter.Status -ne 'Up') { return $false }
    try {
        $ls = [string]$Adapter.LinkSpeed
        if ($ls -match '^(0\s*bps|0$)') { return $false }
    } catch {}
    return $true
}

function Get-TestNics {
    $allPhysical = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
            $_.MediaType -match '802.3|Ethernet'
        })
    foreach ($a in $allPhysical) {
        $media = ''
        try { $media = [string]$a.MediaConnectionState } catch {}
        if (-not (Test-AdapterHasLink -Adapter $a)) {
            Write-Host ("  略過無 Link：{0}  Status={1}  Media={2}  Speed={3}" -f $a.Name, $a.Status, $media, $a.LinkSpeed)
        }
    }

    $physical = @($allPhysical | Where-Object { Test-AdapterHasLink -Adapter $_ })
    $byGuid = @{}
    foreach ($a in $physical) {
        $byGuid[($a.InterfaceGuid.ToString().Trim('{}').ToLower())] = $a
    }

    $ordered = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        $key = $ni.Id.Trim('{}').ToLower()
        if (-not $byGuid.ContainsKey($key)) { continue }
        $a = $byGuid[$key]
        if ($seen.ContainsKey($a.ifIndex)) { continue }
        $seen[$a.ifIndex] = $true

        $desc = "$($ni.Description) $($a.InterfaceDescription) $($a.Name)"
        if ($desc -match 'bluetooth|virtual|hyper-v|vmware|vethernet|vpn|loopback|teredo|isatap|wi-fi direct|wifi direct|hosted network|kernel debug|wan miniport') {
            continue
        }

        $hasGateway = $false
        $routes = @(Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
        if ($routes.Count -gt 0) { $hasGateway = $true }

        [void]$ordered.Add([pscustomobject]@{
                IfIndex    = [int]$a.ifIndex
                Alias      = [string]$a.Name
                Description = [string]$a.InterfaceDescription
                Mac        = [string]$a.MacAddress
                HasGateway = $hasGateway
            })
    }
    return @($ordered.ToArray())
}

function Get-NetworkAddressProperty {
    param([string]$Alias)
    $prop = Get-NetAdapterAdvancedProperty -Name $Alias -RegistryKeyword 'NetworkAddress' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $prop) {
        $prop = Get-NetAdapterAdvancedProperty -Name $Alias -ErrorAction SilentlyContinue |
            Where-Object {
                $_.RegistryKeyword -eq 'NetworkAddress' -or
                $_.DisplayName -match '(?i)Network Address|Locally Administered'
            } |
            Select-Object -First 1
    }
    return $prop
}

function Get-NicSnapshot {
    param($Nic)
    $iface = Get-NetIPInterface -InterfaceIndex $Nic.IfIndex -AddressFamily IPv4 -ErrorAction Stop
    $addrs = @(Get-NetIPAddress -InterfaceIndex $Nic.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' } |
            ForEach-Object { @{ IP = $_.IPAddress; Prefix = [int]$_.PrefixLength } })
    $gws = @(Get-NetRoute -InterfaceIndex $Nic.IfIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty NextHop -Unique)
    $na = Get-NetworkAddressProperty -Alias $Nic.Alias
    $naVal = $null
    if ($na -and $null -ne $na.DisplayValue) {
        $naVal = [string]$na.DisplayValue
        if ($naVal -eq 'Not Present') { $naVal = '' }
    }
    [pscustomobject]@{
        IfIndex         = $Nic.IfIndex
        Alias           = $Nic.Alias
        Mac             = $Nic.Mac
        Description     = $Nic.Description
        Dhcp            = [string]$iface.Dhcp
        WeakHostSend    = [string]$iface.WeakHostSend
        WeakHostReceive = [string]$iface.WeakHostReceive
        Addresses       = $addrs
        Gateways        = @($gws)
        NetworkAddress  = $naVal
    }
}

function Convert-ToInt32 {
    param($Value)
    if ($null -eq $Value) { throw '缺少網卡編號。' }
    if ($Value -is [Array]) { $Value = @($Value)[0] }
    return [int]$Value
}

function Clear-IPv4 {
    param([int]$IfIndex)
    Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } |
        ForEach-Object {
            try {
                Remove-NetIPAddress -InterfaceIndex $IfIndex -IPAddress $_.IPAddress -AddressFamily IPv4 -Confirm:$false -ErrorAction Stop
            } catch {
                & netsh.exe interface ipv4 delete address $IfIndex $_.IPAddress store=active 2>$null | Out-Null
            }
        }
}

function Set-StaticIPv4 {
    param([int]$IfIndex, [string]$IP, [int]$Prefix)
    Set-NetIPInterface -InterfaceIndex $IfIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue | Out-Null
    # 已是目標 IP 且可 Bind：略過清掉重寫，避免拔線後重跑把偶數埠搞掛
    $already = @(Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $IP -and [int]$_.PrefixLength -eq $Prefix })
    if ($already.Count -gt 0 -and (Test-Ipv4Bindable -IP $IP)) {
        return
    }
    Clear-IPv4 -IfIndex $IfIndex
    Start-Sleep -Milliseconds 300
    try {
        New-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -IPAddress $IP -PrefixLength $Prefix -ErrorAction Stop | Out-Null
    } catch {
        $alias = (Get-NetAdapter -InterfaceIndex $IfIndex -ErrorAction SilentlyContinue | Select-Object -First 1).Name
        if (-not $alias) { $alias = "$IfIndex" }
        & netsh.exe interface ipv4 set address name="$alias" static $IP (ConvertTo-SubnetMask $Prefix) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "寫入 $IP 失敗：$($_.Exception.Message)" }
    }
}

function Test-Ipv4Bindable {
    param([string]$IP)
    $socket = New-Object System.Net.Sockets.Socket(
        [System.Net.Sockets.AddressFamily]::InterNetwork,
        [System.Net.Sockets.SocketType]::Dgram,
        [System.Net.Sockets.ProtocolType]::Udp)
    try {
        $socket.Bind((New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($IP), 0)))
        return $true
    } catch {
        return $false
    } finally {
        $socket.Dispose()
    }
}

function Wait-Ipv4Ready {
    param(
        $Nics,
        $AddressByIndex,
        [int]$TimeoutSec = 30,
        [int]$Prefix = 24,
        [switch]$Secondary,
        [switch]$ThrowOnFail
    )
    $started = Get-Date
    $deadline = $started.AddSeconds($TimeoutSec)
    $retried = @{}
    $ready = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]
    do {
        [void]$ready.Clear()
        [void]$failed.Clear()
        $present = @{}
        foreach ($a in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
            if ([string]$a.AddressState -eq 'Preferred' -and [int]$a.PrefixLength -eq $Prefix) {
                $present["$([int]$a.InterfaceIndex)|$($a.IPAddress)"] = $true
            }
        }
        # 剛寫入的位址要先跑完重複位址偵測（約 1–3 秒）才可 Bind；太早重寫只會讓偵測重來
        $mayRetry = ((Get-Date) - $started).TotalSeconds -ge 5
        foreach ($nic in $Nics) {
            $id = [int]$nic.IfIndex
            $want = [string]$AddressByIndex[$id]
            $has = $present.ContainsKey("$id|$want")
            if ($has -and (Test-Ipv4Bindable -IP $want)) {
                [void]$ready.Add($nic)
                continue
            }
            if ($mayRetry -and -not $retried.ContainsKey($id)) {
                $retried[$id] = $true
                try {
                    Write-Host ("  重試寫入 {0} = {1}" -f $nic.Alias, $want)
                    if ($Secondary) {
                        if (-not $has) {
                            New-NetIPAddress -InterfaceIndex $id -AddressFamily IPv4 -IPAddress $want -PrefixLength $Prefix -ErrorAction Stop | Out-Null
                        }
                    }
                    else {
                        Set-StaticIPv4 -IfIndex $id -IP $want -Prefix $Prefix
                    }
                } catch {
                    Write-Host ("  重試失敗 {0}：{1}" -f $nic.Alias, $_.Exception.Message)
                }
            }
            [void]$failed.Add($nic)
        }
        if ($failed.Count -eq 0) {
            Write-Host ("IP 已生效（{0:N1} 秒）。" -f ((Get-Date) - $started).TotalSeconds)
            $script:__ipv4ReadyResult = [pscustomobject]@{
                Ready  = @($ready.ToArray())
                Failed = @()
            }
            return $script:__ipv4ReadyResult
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)

    $names = @($failed | ForEach-Object { '{0}={1}' -f $_.Alias, $AddressByIndex[[int]$_.IfIndex] })
    Write-Host ("部分 IP 無法 Bind，將略過：{0}" -f ($names -join ', '))
    $script:__ipv4ReadyResult = [pscustomobject]@{
        Ready  = @($ready.ToArray())
        Failed = @($failed.ToArray())
    }
    if ($ThrowOnFail) {
        throw ("IP 尚未就緒，無法 Bind：{0}" -f ($names -join ', '))
    }
    return $script:__ipv4ReadyResult
}

function ConvertTo-SubnetMask {
    param([int]$Prefix)
    $mask = [uint32](([math]::Pow(2, 32) - 1) - ([math]::Pow(2, (32 - $Prefix)) - 1))
    $bytes = [BitConverter]::GetBytes($mask)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return ($bytes | ForEach-Object { $_.ToString() }) -join '.'
}

$script:CableProbeSource = @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Text;

public static class CableProbe
{
    public static string[] FindPeers(int[] ifIndexes, string[] ips, int waitMs)
    {
        if (ifIndexes == null || ips == null || ifIndexes.Length != ips.Length)
        {
            throw new ArgumentException("ifIndexes and ips must match.");
        }

        var ears = new List<Ear>();
        try
        {
            for (int i = 0; i < ips.Length; i++)
            {
                ears.Add(Ear.Open(ifIndexes[i], ips[i]));
            }

            var hits = new List<string>();
            for (int s = 0; s < ips.Length; s++)
            {
                string magic = "BIPAIR|" + ifIndexes[s].ToString() + "|" + Guid.NewGuid().ToString("N");
                string[] parts = ips[s].Split('.');
                string broadcast = parts[0] + "." + parts[1] + "." + parts[2] + ".255";
                SendProbe(ifIndexes[s], ips[s], broadcast, magic);

                var deadline = DateTime.UtcNow.AddMilliseconds(waitMs);
                var seen = new HashSet<int>();
                while (DateTime.UtcNow < deadline)
                {
                    foreach (var ear in ears)
                    {
                        ear.Pump();
                        if (ear.IfIndex != ifIndexes[s] && ear.Text.Contains(magic))
                        {
                            seen.Add(ear.IfIndex);
                        }
                    }
                    System.Threading.Thread.Sleep(30);
                }

                foreach (int peer in seen)
                {
                    hits.Add(ifIndexes[s].ToString() + ">" + peer.ToString());
                }
            }
            return hits.ToArray();
        }
        finally
        {
            foreach (var ear in ears)
            {
                ear.Dispose();
            }
        }
    }

    private static void SendProbe(int ifIndex, string sourceIp, string broadcast, string magic)
    {
        var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        try
        {
            socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.Broadcast, true);
            socket.Bind(new IPEndPoint(IPAddress.Parse(sourceIp), 0));
            try
            {
                int ordered = IPAddress.HostToNetworkOrder(ifIndex);
                socket.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, ordered);
            }
            catch (SocketException)
            {
            }
            byte[] data = Encoding.ASCII.GetBytes(magic);
            socket.SendTo(data, new IPEndPoint(IPAddress.Parse(broadcast), 9));
        }
        finally
        {
            socket.Close();
        }
    }

    private sealed class Ear : IDisposable
    {
        public int IfIndex;
        public string Text = "";
        private Socket _socket;
        private readonly byte[] _buffer = new byte[65535];

        public static Ear Open(int ifIndex, string ip)
        {
            var socket = new Socket(AddressFamily.InterNetwork, SocketType.Raw, ProtocolType.IP);
            socket.Bind(new IPEndPoint(IPAddress.Parse(ip), 0));
            socket.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.HeaderIncluded, true);
            byte[] optionIn = BitConverter.GetBytes(1);
            byte[] optionOut = new byte[4];
            socket.IOControl(unchecked((int)0x98000001), optionIn, optionOut);
            socket.Blocking = false;
            return new Ear { IfIndex = ifIndex, _socket = socket };
        }

        public void Pump()
        {
            while (_socket != null && _socket.Available > 0)
            {
                int size = _socket.Receive(_buffer);
                if (size > 0)
                {
                    Text += Encoding.ASCII.GetString(_buffer, 0, size);
                }
            }
        }

        public void Dispose()
        {
            if (_socket != null)
            {
                _socket.Close();
                _socket = null;
            }
        }
    }
}
'@

function Send-ProbePacket {
    param([string]$SourceIp, [string]$Magic)
    $parts = $SourceIp.Split('.')
    $broadcast = '{0}.{1}.{2}.255' -f $parts[0], $parts[1], $parts[2]
    $socket = New-Object System.Net.Sockets.Socket(
        [System.Net.Sockets.AddressFamily]::InterNetwork,
        [System.Net.Sockets.SocketType]::Dgram,
        [System.Net.Sockets.ProtocolType]::Udp)
    try {
        $socket.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::Broadcast, $true)
        $socket.Bind((New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($SourceIp), 0)))
        $payload = [Text.Encoding]::ASCII.GetBytes($Magic)
        $dest = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($broadcast), 9)
        [void]$socket.SendTo($payload, $dest)
    }
    finally {
        $socket.Dispose()
    }
}

function Get-PktmonNicMap {
    $list = (& pktmon.exe list 2>&1 | Out-String)
    $map = @{}
    foreach ($match in [regex]::Matches($list, '(?m)^\s*(\d+)\s+([0-9A-Fa-f]{2}(?:[-:][0-9A-Fa-f]{2}){5})\s+(\S.*?)\s*$')) {
        $mac = $match.Groups[2].Value.ToUpper().Replace(':', '-')
        $map[$mac] = [int]$match.Groups[1].Value
    }
    return $map
}

function Get-RxBytes {
    param(
        [int]$IfIndex,
        [string]$Alias
    )
    $stats = $null
    if ($Alias) {
        $stats = Get-NetAdapterStatistics -Name $Alias -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $stats) {
        $adapter = Get-NetAdapter -InterfaceIndex $IfIndex -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($adapter) {
            $stats = $adapter | Get-NetAdapterStatistics -ErrorAction SilentlyContinue | Select-Object -First 1
        }
    }
    if (-not $stats) { return [int64]0 }
    foreach ($name in @('ReceivedBytes', 'ReceivedUnicastBytes', 'ReceivedUnicastPackets', 'ReceivedPacketCount', 'PacketsReceived')) {
        $prop = $stats.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value) {
            return [int64]$prop.Value
        }
    }
    return [int64]0
}

function Get-TxBytes {
    param([int]$IfIndex, [string]$Alias)
    $stats = $null
    if ($Alias) {
        $stats = Get-NetAdapterStatistics -Name $Alias -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $stats) {
        $adapter = Get-NetAdapter -InterfaceIndex $IfIndex -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($adapter) {
            $stats = $adapter | Get-NetAdapterStatistics -ErrorAction SilentlyContinue | Select-Object -First 1
        }
    }
    if (-not $stats) { return [int64]0 }
    foreach ($name in @('SentBytes', 'TransmittedBytes', 'SentUnicastBytes', 'OutboundBytes')) {
        $prop = $stats.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value) { return [int64]$prop.Value }
    }
    return [int64]0
}

$script:LineFloodSource = @'
using System;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading;

public static class LineFlood
{
    public static int Flood(string sourceIp, string destIp, int ifIndex, long targetBytes, int maxMs, int payloadSize)
    {
        if (targetBytes < 1) targetBytes = 1;
        if (maxMs < 5) maxMs = 5;
        if (payloadSize < 16 || payloadSize > 1472) payloadSize = 1472;
        byte[] payload = new byte[payloadSize];
        new Random().NextBytes(payload);
        Socket socket = null;
        Exception last = null;
        for (int attempt = 0; attempt < 8; attempt++)
        {
            socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            try
            {
                socket.Bind(new IPEndPoint(IPAddress.Parse(sourceIp), 0));
                last = null;
                break;
            }
            catch (Exception ex)
            {
                last = ex;
                socket.Close();
                socket = null;
                Thread.Sleep(150);
            }
        }
        if (socket == null)
        {
            throw last ?? new InvalidOperationException("bind failed");
        }
        try
        {
            try { socket.SendBufferSize = 1024 * 1024; } catch (SocketException) { }
            try { socket.EnableBroadcast = true; } catch (SocketException) { }
            try
            {
                int ordered = IPAddress.HostToNetworkOrder(ifIndex);
                socket.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, ordered);
            }
            catch (SocketException)
            {
                try { socket.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, ifIndex); }
                catch (SocketException) { }
            }
            var dest = new IPEndPoint(IPAddress.Parse(destIp), 9);
            var watch = Stopwatch.StartNew();
            long sentBytes = 0;
            int packets = 0;
            while (sentBytes < targetBytes && watch.ElapsedMilliseconds < maxMs)
            {
                try
                {
                    sentBytes += socket.SendTo(payload, dest);
                    packets++;
                }
                catch (SocketException)
                {
                    if (packets == 0 && watch.ElapsedMilliseconds > 12) break;
                    Thread.Sleep(1);
                }
            }
            return packets;
        }
        finally
        {
            socket.Close();
        }
    }
}
'@

function Initialize-LineFlood {
    if ('LineFlood' -as [type]) { return }
    Add-Type -TypeDefinition $script:LineFloodSource -Language CSharp
}

function Send-UnicastFlood {
    param(
        [string]$SourceIp,
        [string]$DestIp,
        [int]$IfIndex,
        [int64]$TargetBytes,
        [int]$MaxMs = 25,
        [int]$PayloadSize = 1472
    )
    Initialize-LineFlood
    return [int][LineFlood]::Flood($SourceIp, $DestIp, $IfIndex, $TargetBytes, $MaxMs, $PayloadSize)
}

function Initialize-UnicastStatCache {
    $script:__niByAlias = @{}
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        $script:__niByAlias[$ni.Name] = $ni
    }
}

function Get-IfOctets {
    param([string]$Alias)
    if (-not $script:__niByAlias -or -not $script:__niByAlias.ContainsKey($Alias)) {
        Initialize-UnicastStatCache
    }
    $ni = $null
    if ($script:__niByAlias.ContainsKey($Alias)) { $ni = $script:__niByAlias[$Alias] }
    if (-not $ni) { return $null }
    try {
        # 必須用總位元組：同機送往本機 IP 的 UDP 多半不上線，線上實際是 ARP 等廣播，單播計數會是 0
        $stats = $ni.GetIPStatistics()
        return [pscustomobject]@{
            Rx = [int64]$stats.BytesReceived
            Tx = [int64]$stats.BytesSent
        }
    } catch {
        return $null
    }
}

function Get-LinkBitsPerSec {
    param([string]$Alias)
    if (-not $script:__niByAlias -or -not $script:__niByAlias.ContainsKey($Alias)) {
        Initialize-UnicastStatCache
    }
    $speed = [int64]0
    if ($script:__niByAlias.ContainsKey($Alias)) {
        try { $speed = [int64]$script:__niByAlias[$Alias].Speed } catch {}
    }
    if ($speed -lt 10000000) { $speed = [int64]1000000000 }
    return $speed
}

# 10/21 已在實機確認可配對的量法：同一 /16、WMI 位元組、每方向兩輪 90 個 256B 包。
function Measure-LegacyRx {
    param($Src, $Cand, $IpByIndex, [int]$Count = 90)
    $srcIp = [string]$IpByIndex[[int]$Src.IfIndex]
    $destIp = [string]$IpByIndex[[int]$Cand.IfIndex]
    $rx = [int64]0
    $tx = [int64]0
    for ($round = 0; $round -lt 2; $round++) {
        $rxBefore = Get-RxBytes -IfIndex $Cand.IfIndex -Alias $Cand.Alias
        $txBefore = Get-TxBytes -IfIndex $Src.IfIndex -Alias $Src.Alias
        $null = Send-UnicastFlood -SourceIp $srcIp -DestIp $destIp -IfIndex ([int]$Src.IfIndex) -TargetBytes ($Count * 256) -MaxMs 3000 -PayloadSize 256
        Start-Sleep -Milliseconds 120
        $dr = (Get-RxBytes -IfIndex $Cand.IfIndex -Alias $Cand.Alias) - $rxBefore
        $dt = (Get-TxBytes -IfIndex $Src.IfIndex -Alias $Src.Alias) - $txBefore
        if ($dr -gt 0) { $rx += $dr }
        if ($dt -gt 0) { $tx += $dt }
    }
    return [pscustomobject]@{ Rx = [int64]$rx; Tx = [int64]$tx }
}

# 主量法用：在正式 IP 旁加一個各自獨立 /24 的探測 IP，正式 IP 不動，量完只要刪掉探測 IP
function Add-ProbeAddresses {
    param($Nics)
    $map = @{}
    $byIf = @{}
    foreach ($a in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        $k = [int]$a.InterfaceIndex
        if (-not $byIf.ContainsKey($k)) { $byIf[$k] = @() }
        $byIf[$k] += ,$a
    }
    $ordinal = 1
    foreach ($nic in $Nics) {
        $id = [int]$nic.IfIndex
        $probeIp = '10.250.{0}.1' -f $ordinal
        $have = $false
        foreach ($a in @($byIf[$id])) {
            if (-not $a) { continue }
            if ([string]$a.IPAddress -like '10.250.*') {
                if ([string]$a.IPAddress -eq $probeIp -and [int]$a.PrefixLength -eq 24) { $have = $true; continue }
                Remove-NetIPAddress -InterfaceIndex $id -IPAddress $a.IPAddress -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
        if (-not $have) {
            New-NetIPAddress -InterfaceIndex $id -AddressFamily IPv4 -IPAddress $probeIp -PrefixLength 24 -ErrorAction Stop | Out-Null
        }
        $map[$id] = $probeIp
        Write-Host ("  探測用  {0} += {1}/24" -f $nic.Alias, $probeIp)
        $ordinal++
    }
    $null = Wait-Ipv4Ready -Nics $Nics -AddressByIndex $map -TimeoutSec 30 -Prefix 24 -Secondary -ThrowOnFail
    Initialize-UnicastStatCache
    $script:__probeMap = $map
}

function Remove-ProbeAddresses {
    param($Nics)
    $want = @{}
    foreach ($nic in $Nics) { $want[[int]$nic.IfIndex] = $true }
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -like '10.250.*' -and $want.ContainsKey([int]$_.InterfaceIndex) } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction Stop
}

# 原量法用：整個換成同一 /16（會拿掉正式 IP，量完必須重寫）
function Set-ProbeAddresses {
    param($Nics, [int]$Prefix)
    $script:__probeReplaced = $true
    $map = @{}
    $ordinal = 1
    foreach ($nic in $Nics) {
        $probeIp = '10.250.{0}.1' -f $ordinal
        Set-StaticIPv4 -IfIndex $nic.IfIndex -IP $probeIp -Prefix $Prefix
        $map[[int]$nic.IfIndex] = $probeIp
        Write-Host ("  探測用  {0} = {1}/{2}" -f $nic.Alias, $probeIp, $Prefix)
        $ordinal++
    }
    $null = Wait-Ipv4Ready -Nics $Nics -AddressByIndex $map -TimeoutSec 30 -Prefix $Prefix -ThrowOnFail
    Initialize-UnicastStatCache
    $script:__probeMap = $map
}

# 每張網卡在自己的 /24 送子網廣播。廣播不用 ARP，會真的灌上線；只有直連對端的硬體收位元組會暴增。
function Measure-BroadcastRows {
    param($Nics, $IpMap, [int]$BurstMs = 30, [int]$Rounds = 2)
    $score = @{}
    $i = 0
    foreach ($src in $Nics) {
        $i++
        Write-UiProgress (45 + [int](30.0 * $i / $Nics.Count)) ("偵測網路線：$($src.Alias)")
        $sid = [int]$src.IfIndex
        $row = @{}
        foreach ($d in $Nics) { if ([int]$d.IfIndex -ne $sid) { $row[[int]$d.IfIndex] = [int64]0 } }
        $srcIp = [string]$IpMap[$sid]
        $p = $srcIp.Split('.')
        $bcast = '{0}.{1}.{2}.255' -f $p[0], $p[1], $p[2]
        $speed = Get-LinkBitsPerSec -Alias $src.Alias
        $target = [int64](($speed / 8) * $BurstMs / 1000)
        if ($target -lt 200000) { $target = 200000 }
        $txSum = [int64]0
        $sentSum = 0
        for ($r = 0; $r -lt $Rounds; $r++) {
            $before = @{}
            foreach ($n in $Nics) { $before[[int]$n.IfIndex] = Get-IfOctets -Alias $n.Alias }
            $sentSum += Send-UnicastFlood -SourceIp $srcIp -DestIp $bcast -IfIndex $sid -TargetBytes $target -MaxMs $BurstMs
            Start-Sleep -Milliseconds 80
            foreach ($n in $Nics) {
                $id = [int]$n.IfIndex
                $a = Get-IfOctets -Alias $n.Alias
                $b = $before[$id]
                if (-not $a -or -not $b) { continue }
                if ($id -eq $sid) {
                    $dt = [int64]$a.Tx - [int64]$b.Tx
                    if ($dt -gt 0) { $txSum += $dt }
                }
                else {
                    $dr = [int64]$a.Rx - [int64]$b.Rx
                    if ($dr -gt 0) { $row[$id] = [int64]$row[$id] + $dr }
                }
            }
        }
        $score[$sid] = $row
        $ranked = @($Nics | Where-Object { [int]$_.IfIndex -ne $sid } |
            Sort-Object { [int64]$row[[int]$_.IfIndex] } -Descending)
        $top = $ranked | Select-Object -First 2
        $desc = ($top | ForEach-Object { '{0}={1}' -f $_.Alias, $row[[int]$_.IfIndex] }) -join '  '
        Write-Host ("    {0} 廣播 sent={1} Tx+{2} @{3}Mbps → 收最多：{4}" -f $src.Alias, $sentSum, $txSum, [int]($speed / 1000000), $desc)
    }
    $script:__broadcastScore = $score
}

function Measure-LegacyRows {
    param($Nics, $IpMap)
    $score = @{}
    $order = @($Nics)
    [Array]::Reverse($order)
    $total = [Math]::Max(1, $Nics.Count * ($Nics.Count - 1))
    $done = 0
    foreach ($src in $order) {
        $row = @{}
        $txTotal = [int64]0
        foreach ($dst in $Nics) {
            if ($src.IfIndex -eq $dst.IfIndex) { continue }
            $done++
            Write-UiProgress (75 + [int](15.0 * $done / $total)) ("再次確認網路線：$($src.Alias) → $($dst.Alias)")
            $m = Measure-LegacyRx -Src $src -Cand $dst -IpByIndex $IpMap -Count 90
            $row[[int]$dst.IfIndex] = [int64]$m.Rx
            $txTotal += [int64]$m.Tx
            Write-Host ("    {0} -> {1}  Rx+{2}  Tx+{3}" -f $src.Alias, $dst.Alias, $m.Rx, $m.Tx)
        }
        if ($txTotal -le 0) {
            Write-Host ("  {0} Tx+0，重綁探測 IP 後重測…" -f $src.Alias)
            Set-StaticIPv4 -IfIndex $src.IfIndex -IP $IpMap[[int]$src.IfIndex] -Prefix 16
            Start-Sleep -Milliseconds 800
            foreach ($dst in $Nics) {
                if ($src.IfIndex -eq $dst.IfIndex) { continue }
                $m = Measure-LegacyRx -Src $src -Cand $dst -IpByIndex $IpMap -Count 120
                $row[[int]$dst.IfIndex] = [int64]$m.Rx
                Write-Host ("    {0} -> {1}  Rx+{2}  Tx+{3}（重測）" -f $src.Alias, $dst.Alias, $m.Rx, $m.Tx)
            }
        }
        $score[[int]$src.IfIndex] = $row
        Start-Sleep -Milliseconds 80
    }
    $script:__legacyScore = $score
}

function Resolve-CablePairs {
    param($Nics, $Score, [int64]$MinSum, [string]$Label)
    $weight = @{}
    $sumRx = @{}
    Write-Host ("[{0}] 邊權重（Rx 雙向合計，位元組）：" -f $Label)
    for ($i = 0; $i -lt $Nics.Count; $i++) {
        for ($j = $i + 1; $j -lt $Nics.Count; $j++) {
            $a = [int]$Nics[$i].IfIndex
            $b = [int]$Nics[$j].IfIndex
            $ab = [int64]0
            $ba = [int64]0
            if ($Score.ContainsKey($a) -and $Score[$a].ContainsKey($b)) { $ab = [int64]$Score[$a][$b] }
            if ($Score.ContainsKey($b) -and $Score[$b].ContainsKey($a)) { $ba = [int64]$Score[$b][$a] }
            $sum = $ab + $ba
            $sumRx["$a|$b"] = $sum
            $sumRx["$b|$a"] = $sum
            $weight["$a|$b"] = $sum
            $weight["$b|$a"] = $sum
            if ($sum -gt 0) {
                Write-Host ("  {0} <-> {1}  {0}->{1}={2}  {1}->{0}={3}  sum={4}" -f `
                    $Nics[$i].Alias, $Nics[$j].Alias, $ab, $ba, $sum)
            }
        }
    }

    $accepted = @(Find-ReciprocalPairs -Nics $Nics -Score $Score -SumRx $sumRx -MinSum $MinSum)
    if (($Nics.Count % 2) -eq 0 -and $accepted.Count -lt ($Nics.Count / 2)) {
        $bestPairs = @(Find-BestPairMatching -Nics $Nics -Weight $weight)
        if ($bestPairs.Count -eq ($Nics.Count / 2)) {
            $okAll = $true
            foreach ($p in $bestPairs) {
                if ([int64]$sumRx["$([int]$p.A.IfIndex)|$([int]$p.B.IfIndex)"] -lt $MinSum) { $okAll = $false; break }
            }
            if ($okAll) { $accepted = $bestPairs }
        }
    }
    Write-Host ("[{0}] 確認的線：" -f $Label)
    if ($accepted.Count -eq 0) { Write-Host '  （無）' }
    foreach ($p in $accepted) {
        Write-Host ("  {0} <-> {1}  sum={2}" -f $p.A.Alias, $p.B.Alias, $sumRx["$([int]$p.A.IfIndex)|$([int]$p.B.IfIndex)"])
    }
    $script:__resolvedPairs = @($accepted)
}

function Get-CablePairs {
    param($Nics, $AddressByIndex)

    $script:__cablePairResult = [pscustomobject]@{ Ok = $false; Pairs = @() }
    if ($Nics.Count -lt 2) {
        Write-Host '可對接網卡少於 2 張，跳過對接。'
        return $script:__cablePairResult
    }

    $statusByIf = @{}
    foreach ($ad in @(Get-NetAdapter -ErrorAction SilentlyContinue)) { $statusByIf[[int]$ad.ifIndex] = [string]$ad.Status }
    $upNics = @()
    foreach ($nic in $Nics) {
        $st = 'Missing'
        if ($statusByIf.ContainsKey([int]$nic.IfIndex)) { $st = $statusByIf[[int]$nic.IfIndex] }
        if ($st -eq 'Up') {
            $upNics += ,$nic
        }
        else {
            Write-Host ("  對接前略過（非 Up）：{0} Status={1}" -f $nic.Alias, $st)
        }
    }
    if ($upNics.Count -lt 2) {
        Write-Host 'Up 狀態網卡不足 2 張，跳過對接（IP 已保留）。'
        return $script:__cablePairResult
    }
    $Nics = $upNics

    $script:__cablePairResult = [pscustomobject]@{ Ok = $false; Pairs = @() }
    $finalIp = @{}
    foreach ($nic in $Nics) {
        $final = [string]$AddressByIndex[[int]$nic.IfIndex]
        if (-not $final) { throw "缺少 $($nic.Alias) 的本機 IP，無法探測。" }
        $finalIp[[int]$nic.IfIndex] = $final
    }

    $script:__probeReplaced = $false
    try {
        $needPairs = [Math]::Floor($Nics.Count / 2)

        # 主量法：各埠加一個獨立 /24 探測 IP，輪流送子網廣播，看哪張網卡硬體收到大量位元組。
        # 實機差距約 1.4–1.9 千萬 vs 1 千位元組，一輪就分得出來。
        Write-Host '加上探測 IP（各埠獨立網段，正式 IP 保留）…'
        Add-ProbeAddresses -Nics $Nics
        Measure-BroadcastRows -Nics $Nics -IpMap $script:__probeMap -BurstMs 30 -Rounds 1
        Resolve-CablePairs -Nics $Nics -Score $script:__broadcastScore -MinSum 100000 -Label '廣播'
        $accepted = @($script:__resolvedPairs)

        # 保底：沒配滿就跑 10/21 實機確認過的原量法（同 /16、所有方向），取配到較多的結果
        if ($accepted.Count -lt $needPairs) {
            Write-Host ("廣播量法只確認 {0}/{1} 條，改用原量法完整重測（較慢）…" -f $accepted.Count, $needPairs)
            Remove-ProbeAddresses -Nics $Nics
            Set-ProbeAddresses -Nics $Nics -Prefix 16
            Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $finalIp.ContainsKey([int]$_.InterfaceIndex) -and $_.IPAddress -like '10.250.*' } |
                Remove-NetNeighbor -Confirm:$false -ErrorAction SilentlyContinue
            Measure-LegacyRows -Nics $Nics -IpMap $script:__probeMap
            Resolve-CablePairs -Nics $Nics -Score $script:__legacyScore -MinSum 50 -Label '原量法'
            $legacyPairs = @($script:__resolvedPairs)
            if ($legacyPairs.Count -gt $accepted.Count) { $accepted = $legacyPairs }
        }

        if ($accepted.Count -ge 1) {
            Write-Host ("最終確認 {0} 條網路線。" -f $accepted.Count)
            $script:__cablePairResult = [pscustomobject]@{ Ok = $true; Pairs = @($accepted) }
        }
        else {
            Write-Host '沒有確認到網路線 → 只設定 IP。'
            $script:__cablePairResult = [pscustomobject]@{ Ok = $false; Pairs = @() }
        }
    }
    finally {
        Write-UiProgress 92 '套用測試 IP'
        $cleanupErrors = @()
        foreach ($nic in $Nics) {
            try { Remove-ProbeAddresses -Nics @($nic) } catch {
                $cleanupErrors += "$($nic.Alias): $($_.Exception.Message)"
            }
            if ($script:__probeReplaced) {
                try { Set-StaticIPv4 -IfIndex $nic.IfIndex -IP $finalIp[[int]$nic.IfIndex] -Prefix 24 } catch {
                    $cleanupErrors += "$($nic.Alias): $($_.Exception.Message)"
                }
            }
        }
        if ($cleanupErrors.Count) { throw ("網卡設定還原失敗：" + ($cleanupErrors -join '；')) }
        $null = Wait-Ipv4Ready -Nics $Nics -AddressByIndex $finalIp -TimeoutSec 30 -ThrowOnFail
    }

    # 用單一物件回傳，避免 PowerShell 陣列被拆/被包成 Count=1
    if (-not $script:__cablePairResult) {
        $script:__cablePairResult = [pscustomobject]@{ Ok = $false; Pairs = @() }
    }
    return $script:__cablePairResult
}

function Find-BestPairMatching {
    param($Nics, $Weight)

    $n = $Nics.Count
    # 遞迴搜尋完美配對（8 埠只有 105 種，可窮舉）
    $script:__pairBestScore = [int64]-1
    $script:__pairBestEdges = $null
    $script:__pairNics = $Nics
    $script:__pairWeight = $Weight

    function Invoke-PairSearch {
        param([System.Collections.Generic.List[int]]$Left, [System.Collections.Generic.List[object]]$Chosen, [int64]$ScoreSoFar)
        if ($Left.Count -eq 0) {
            if ($ScoreSoFar -gt $script:__pairBestScore) {
                $script:__pairBestScore = $ScoreSoFar
                $script:__pairBestEdges = @($Chosen.ToArray())
            }
            return
        }
        $i = $Left[0]
        for ($t = 1; $t -lt $Left.Count; $t++) {
            $j = $Left[$t]
            $na = $script:__pairNics[$i]
            $nb = $script:__pairNics[$j]
            $w = [int64]$script:__pairWeight["$([int]$na.IfIndex)|$([int]$nb.IfIndex)"]
            $nextLeft = New-Object System.Collections.Generic.List[int]
            for ($u = 1; $u -lt $Left.Count; $u++) {
                if ($u -ne $t) { [void]$nextLeft.Add([int]$Left[$u]) }
            }
            $nextChosen = New-Object System.Collections.Generic.List[object]
            foreach ($c in $Chosen) { [void]$nextChosen.Add($c) }
            [void]$nextChosen.Add([pscustomobject]@{ A = $na; B = $nb })
            Invoke-PairSearch -Left $nextLeft -Chosen $nextChosen -ScoreSoFar ($ScoreSoFar + $w)
        }
    }

    $left = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $n; $i++) { [void]$left.Add($i) }
    Invoke-PairSearch -Left $left -Chosen (New-Object System.Collections.Generic.List[object]) -ScoreSoFar 0
    return @($script:__pairBestEdges)
}

function Find-ReciprocalPairs {
    param($Nics, $Score, $SumRx, [int64]$MinSum = 50)
    # 每個埠的「最強對端」= 對端硬體 Rx 最高者
    $best = @{}
    $bestVal = @{}
    foreach ($src in $Nics) {
        $sid = [int]$src.IfIndex
        $topId = -1
        $topRx = [int64]-1
        foreach ($dst in $Nics) {
            if ($src.IfIndex -eq $dst.IfIndex) { continue }
            $rx = [int64]0
            if ($Score.ContainsKey($sid) -and $Score[$sid].ContainsKey([int]$dst.IfIndex)) {
                $rx = [int64]$Score[$sid][[int]$dst.IfIndex]
            }
            if ($rx -gt $topRx) {
                $topRx = $rx
                $topId = [int]$dst.IfIndex
            }
        }
        # Rx 全 0 不宣稱有最強對端（避免 Tx 死掉時亂指第一個）
        if ($topRx -le 0) { $topId = -1 }
        $best[$sid] = $topId
        $bestVal[$sid] = $topRx
    }

    $byIndex = @{}
    foreach ($n in $Nics) { $byIndex[[int]$n.IfIndex] = $n }

    $candidates = @()
    foreach ($src in $Nics) {
        $a = [int]$src.IfIndex
        $b = [int]$best[$a]
        if ($b -lt 0) { continue }
        if (-not $best.ContainsKey($b) -or [int]$best[$b] -ne $a) { continue }  # 必須互為第一名
        if ($a -gt $b) { continue }             # 每條線只列一次
        $sum = [int64]$SumRx["$a|$b"]
        if ($sum -lt $MinSum) { continue }
        $candidates += ,[pscustomobject]@{
            A = $byIndex[$a]
            B = $byIndex[$b]
            Sum = $sum
        }
    }

    # 若有衝突（理論上互惠不會），依 sum 高者優先
    $candidates = @($candidates | Sort-Object Sum -Descending)
    $used = @{}
    $pairs = @()
    foreach ($c in $candidates) {
        $ai = [int]$c.A.IfIndex
        $bi = [int]$c.B.IfIndex
        if ($used.ContainsKey($ai) -or $used.ContainsKey($bi)) { continue }
        $used[$ai] = $true
        $used[$bi] = $true
        $pairs += ,[pscustomobject]@{ A = $c.A; B = $c.B }
    }
    return @($pairs)
}

function Get-AdapterStatus {
    param([int]$IfIndex)
    $adapter = Get-NetAdapter -InterfaceIndex $IfIndex -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $adapter) { return 'Missing' }
    return [string]$adapter.Status
}

function Set-TestPortHostMode {
    param($Nics)
    foreach ($nic in $Nics) {
        $id = [int]$nic.IfIndex
        $iface = Get-NetIPInterface -InterfaceIndex $id -AddressFamily IPv4 -ErrorAction Stop
        Write-Host ("  {0} WeakHostSend={1} WeakHostReceive={2}" -f $nic.Alias, $iface.WeakHostSend, $iface.WeakHostReceive)
        if ([string]$iface.WeakHostSend -eq 'Disabled' -and [string]$iface.WeakHostReceive -eq 'Disabled') { continue }
        Set-NetIPInterface -InterfaceIndex $id -AddressFamily IPv4 -WeakHostSend Disabled -WeakHostReceive Disabled -ErrorAction Stop
        $iface = Get-NetIPInterface -InterfaceIndex $id -AddressFamily IPv4 -ErrorAction Stop
        if ([string]$iface.WeakHostSend -ne 'Disabled' -or [string]$iface.WeakHostReceive -ne 'Disabled') {
            throw "$($nic.Alias) 無法恢復 Windows 預設的 IPv4 收送模式。"
        }
        Write-Host ("  {0} 已關閉 IPv4 Weak Host。" -f $nic.Alias)
    }
}

function Test-PairReachable {
    param($Nics, $LocalIp, $DestIp)
    $ok = $true
    foreach ($nic in $Nics) {
        $src = [string]$LocalIp[[int]$nic.IfIndex]
        $dst = [string]$DestIp[[int]$nic.IfIndex]
        & ping.exe -S $src -n 2 -w 800 $dst 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host ("  通：{0} ({1}) -> {2}" -f $nic.Alias, $src, $dst)
        }
        else {
            Write-Host ("  不通：{0} ({1}) -> {2}" -f $nic.Alias, $src, $dst)
            $ok = $false
        }
    }
    return $ok
}

function Remove-ProbeAddress {
    param([int]$IfIndex)
    Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like '10.255.*' -or $_.IPAddress -like '10.250.*' } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    $left = @(Get-NetIPAddress -InterfaceIndex $IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' })
    if ($left.Count -eq 0) {
        Set-NetIPInterface -InterfaceIndex $IfIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction SilentlyContinue | Out-Null
    }
}

function Enable-IcmpEcho {
    $existing = Get-NetFirewallRule -DisplayName 'BurnIn LAN ICMP echo' -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-NetFirewallRule -DisplayName 'BurnIn LAN ICMP echo' -Direction Inbound -Action Allow -Protocol ICMPv4 -IcmpType 8 -Profile Any | Out-Null
    }
    else {
        Set-NetFirewallRule -DisplayName 'BurnIn LAN ICMP echo' -Enabled True -Action Allow | Out-Null
    }
}

function Set-LocalAdministeredMac {
    param(
        [string]$Alias,
        [string]$Mac12
    )
    $flat = Normalize-Mac -Mac $Mac12
    if ($flat.Length -ne 12) { throw "MAC 格式錯誤：$Mac12" }
    $prop = Get-NetworkAddressProperty -Alias $Alias
    if (-not $prop) {
        throw "$Alias 不支援 Network Address，無法改 MAC。"
    }
    Set-NetAdapterAdvancedProperty -Name $Alias -RegistryKeyword $prop.RegistryKeyword -DisplayValue $flat -ErrorAction Stop
    # Intel 等驅動通常要短暫停用再開才生效
    Disable-NetAdapter -Name $Alias -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    Enable-NetAdapter -Name $Alias -Confirm:$false -ErrorAction Stop
    Start-Sleep -Seconds 2
}

function Clear-LocalAdministeredMac {
    param([string]$Alias)
    $prop = Get-NetworkAddressProperty -Alias $Alias
    if (-not $prop) { return }
    try {
        Set-NetAdapterAdvancedProperty -Name $Alias -RegistryKeyword $prop.RegistryKeyword -DisplayValue '' -ErrorAction Stop
    } catch {
        try {
            Set-NetAdapterAdvancedProperty -Name $Alias -RegistryKeyword $prop.RegistryKeyword -DisplayValue '0' -ErrorAction SilentlyContinue
        } catch {}
    }
    Disable-NetAdapter -Name $Alias -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    Enable-NetAdapter -Name $Alias -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function New-PairToolMac {
    param([int]$IfIndex, [int]$Seq)
    # Locally administered + unicast（第二個半位元組為 2）
    $bytes = @(
        0x02,
        0x50,
        [byte](($IfIndex -shr 8) -band 0xFF),
        [byte]($IfIndex -band 0xFF),
        [byte](($Seq -shr 8) -band 0xFF),
        [byte]($Seq -band 0xFF)
    )
    return (($bytes | ForEach-Object { $_.ToString('X2') }) -join '')
}

function Update-NicMacFromSystem {
    param($NicList)
    foreach ($nic in $NicList) {
        $adapter = Get-NetAdapter -InterfaceIndex $nic.IfIndex -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($adapter) {
            $nic.Mac = [string]$adapter.MacAddress
        }
    }
}

function Repair-DuplicateMacs {
    param($NicList)
    Update-NicMacFromSystem -NicList $NicList
    $groups = @($NicList | Group-Object { Normalize-Mac -Mac $_.Mac } | Where-Object { $_.Name -and $_.Count -gt 1 })
    if ($groups.Count -eq 0) {
        Write-Host 'MAC 無重複，不改 MAC。'
        return @()
    }

    $changed = New-Object System.Collections.Generic.List[string]
    $seq = 1
    $used = @{}
    foreach ($nic in $NicList) {
        $m = Normalize-Mac -Mac $nic.Mac
        if ($m) { $used[$m] = $true }
    }

    foreach ($g in $groups) {
        Write-Host ("發現重複 MAC {0}（{1} 張），保留第一張，其餘改寫：" -f $g.Name, $g.Count)
        $first = $true
        foreach ($nic in @($g.Group)) {
            if ($first) {
                Write-Host ("  保留 {0} = {1}" -f $nic.Alias, $nic.Mac)
                $first = $false
                continue
            }
            do {
                $newFlat = New-PairToolMac -IfIndex ([int]$nic.IfIndex) -Seq $seq
                $seq++
            } while ($used.ContainsKey($newFlat))
            $used[$newFlat] = $true
            $pretty = ((0..5 | ForEach-Object { $newFlat.Substring($_ * 2, 2) }) -join '-')
            Write-Host ("  改寫 {0}：{1} → {2}" -f $nic.Alias, $nic.Mac, $pretty)
            Set-LocalAdministeredMac -Alias $nic.Alias -Mac12 $newFlat
            [void]$changed.Add($nic.Alias)
        }
    }
    Update-NicMacFromSystem -NicList $NicList
    Write-Host '重複 MAC 已改寫完成（本機 Locally Administered Address）。'
    return @($changed.ToArray())
}

function Normalize-Mac {
    param([string]$Mac)
    if (-not $Mac) { return '' }
    return (($Mac -replace '[^0-9A-Fa-f]', '')).ToUpperInvariant()
}

function Restore-Backup {
    if (-not (Test-Path $BackupPath)) {
        throw "找不到備份：$BackupPath"
    }
    $items = Get-Content -Raw -Path $BackupPath | ConvertFrom-Json
    foreach ($item in @($items)) {
        $ifIndex = Convert-ToInt32 $item.IfIndex
        $alias = [string]$item.Alias

        # 先還原／清除我們改過的 MAC（Network Address）
        if ($alias -and $item.PSObject.Properties['NetworkAddress']) {
            $prev = [string]$item.NetworkAddress
            try {
                if ([string]::IsNullOrWhiteSpace($prev)) {
                    Write-Host ("還原 MAC（清除 LAA）：{0}" -f $alias)
                    Clear-LocalAdministeredMac -Alias $alias
                }
                else {
                    Write-Host ("還原 MAC Network Address：{0} → {1}" -f $alias, $prev)
                    Set-LocalAdministeredMac -Alias $alias -Mac12 (Normalize-Mac -Mac $prev)
                }
            } catch {
                Write-Host ("還原 MAC 失敗 {0}：{1}" -f $alias, $_.Exception.Message)
            }
        }

        if ($item.WeakHostSend -in 'Enabled','Disabled' -and $item.WeakHostReceive -in 'Enabled','Disabled') {
            Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -WeakHostSend $item.WeakHostSend -WeakHostReceive $item.WeakHostReceive -ErrorAction Stop
        }
        Clear-IPv4 -IfIndex $ifIndex
        if ([string]$item.Dhcp -eq 'Enabled' -and @($item.Addresses).Count -eq 0) {
            Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -Dhcp Enabled | Out-Null
            continue
        }
        Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue | Out-Null
        foreach ($addr in @($item.Addresses)) {
            if (-not $addr.IP) { continue }
            New-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -IPAddress ([string]$addr.IP) -PrefixLength (Convert-ToInt32 $addr.Prefix) -ErrorAction SilentlyContinue | Out-Null
        }
        foreach ($gw in @($item.Gateways)) {
            if ($gw) {
                New-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop ([string]$gw) -ErrorAction SilentlyContinue | Out-Null
            }
        }
        if ([string]$item.Dhcp -eq 'Enabled') {
            Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -Dhcp Enabled -ErrorAction SilentlyContinue | Out-Null
        }
    }
    Write-Host "已依備份還原：$BackupPath"
}

if ($Restore) {
    if (Test-Path -LiteralPath $StatePath) { Remove-Item -LiteralPath $StatePath -ErrorAction Stop }
    Restore-Backup
    Wait-Exit
    return
}

try {
$all = @(Get-TestNics)
$skipped = @($all | Where-Object { $_.HasGateway })
$nics = @($all | Where-Object { -not $_.HasGateway })

Write-Host ''
Write-Host 'BurnInTest 會依下面這個順序綁定目的位址（有預設閘道的網卡已略過）。'
$n = 1
foreach ($nic in $nics) {
    Write-Host ("  {0,2}. {1}  MAC {2}" -f $n, $nic.Alias, $nic.Mac)
    $n++
}
foreach ($nic in $skipped) {
    Write-Host ("  略過（有預設閘道，視為上網網卡）: {0}  MAC {1}" -f $nic.Alias, $nic.Mac)
}

if ($List) {
    Wait-Exit
    return
}

function Get-EthernetNumber {
    param([string]$Alias)
    if ($Alias -match '(?i)(?:Ethernet|乙太網路)\s*(\d+)') {
        return [int]$Matches[1]
    }
    if ($Alias -match '(?i)^(Ethernet|乙太網路)$') {
        return 1
    }
    return $null
}


function Find-FreeHostOctet {
    param([hashtable]$UsedHost, [int]$Start)
    $h = [Math]::Max(1, [Math]::Min(254, $Start))
    for ($n = 0; $n -lt 254; $n++) {
        $try = (($h - 1 + $n) % 254) + 1
        if (-not $UsedHost.ContainsKey($try)) { return $try }
    }
    throw '192.168.1.x 已無可用位址。'
}

function Build-LocalIpMap {
    param($NicList)
    $macCount = @{}
    foreach ($nic in $NicList) {
        $m = Normalize-Mac -Mac $nic.Mac
        if (-not $m) { continue }
        if (-not $macCount.ContainsKey($m)) { $macCount[$m] = 0 }
        $macCount[$m]++
    }

    $dupMacs = @($macCount.Keys | Where-Object { $macCount[$_] -gt 1 } | Sort-Object)
    if ($dupMacs.Count -gt 0) {
        Write-Host '警告：規劃 IP 時仍看到重複 MAC（改 MAC 可能未成功）：'
        foreach ($m in $dupMacs) {
            $names = @($NicList | Where-Object { (Normalize-Mac -Mac $_.Mac) -eq $m } | ForEach-Object { $_.Alias })
            Write-Host ("  MAC {0} → {1}" -f $m, ($names -join ', '))
        }
    }

    $localIp = @{}
    $usedHost = @{}
    $testIndexes = @($NicList | ForEach-Object { [int]$_.IfIndex })
    foreach ($address in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)) {
        if ($testIndexes -contains [int]$address.InterfaceIndex) { continue }
        if ([string]$address.IPAddress -match '^192\.168\.1\.(\d+)$') {
            $usedHost[[int]$Matches[1]] = $true
        }
    }
    foreach ($nic in $NicList) {
        $base = Get-EthernetNumber -Alias $nic.Alias
        if (-not $base) {
            $base = ([int]$nic.IfIndex % 200) + 1
            Write-Host ("  {0} 無法從名稱取編號，改用 IfIndex 衍生尾數 {1}" -f $nic.Alias, $base)
        }
        $hostNum = Find-FreeHostOctet -UsedHost $usedHost -Start $base
        if ($hostNum -ne $base) {
            Write-Host ("  {0} 尾數 {1} 已被占用，改用 {2}" -f $nic.Alias, $base, $hostNum)
        }
        $usedHost[$hostNum] = $true
        $localIp[[int]$nic.IfIndex] = "192.168.1.$hostNum"
    }

    [pscustomobject]@{
        Local = $localIp
        DuplicateMacs = $dupMacs
    }
}

function Get-AddressPlan {
    param($PairList, $NicList, $LocalMap = $null)
    $items = @()
    if ($null -ne $PairList) {
        foreach ($item in $PairList) { $items += ,$item }
    }

    $planLocal = @{}
    if ($null -ne $LocalMap) {
        foreach ($key in @($LocalMap.Keys)) {
            $planLocal[[int]$key] = [string]$LocalMap[$key]
        }
    }
    else {
        $built = Build-LocalIpMap -NicList $NicList
        $planLocal = $built.Local
    }

    $planDest = @{}
    foreach ($pair in $items) {
        $a = [int]$pair.A.IfIndex
        $b = [int]$pair.B.IfIndex
        $planDest[$a] = $planLocal[$b]
        $planDest[$b] = $planLocal[$a]
    }
    foreach ($nic in $NicList) {
        if (-not $planDest.ContainsKey([int]$nic.IfIndex)) {
            throw "$($nic.Alias) 沒有對接對端，無法決定 BurnInTest 目的 IP。"
        }
    }
    [pscustomobject]@{ Local = $planLocal; Dest = $planDest }
}

function Set-BurnInPowerAndFirewall {
    $highPerf = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    $active = & powercfg.exe /getactivescheme 2>&1 | Out-String
    if ($active -notmatch $highPerf) {
        $list = & powercfg.exe /list 2>&1 | Out-String
        if ($list -notmatch $highPerf) {
            & powercfg.exe -duplicatescheme $highPerf 2>&1 | Out-Null
        }
        & powercfg.exe /setactive $highPerf
        if ($LASTEXITCODE -ne 0) {
            Write-Host '高效能電源配置切換失敗。'
        }
        else {
            Write-Host '電源配置已改為高效能。'
        }
    }
    else {
        Write-Host '電源配置已是高效能。'
    }

    & powercfg.exe /change monitor-timeout-ac 0
    & powercfg.exe /change monitor-timeout-dc 0
    & powercfg.exe /change standby-timeout-ac 0
    & powercfg.exe /change standby-timeout-dc 0
    & powercfg.exe /change hibernate-timeout-ac 0
    & powercfg.exe /change hibernate-timeout-dc 0
    & powercfg.exe /hibernate off
    Write-Host '關閉顯示器、睡眠、休眠都已設為永不。'

    try {
        Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
        Write-Host '防火牆已關閉。'
    }
    catch {
        Write-Host "防火牆關閉失敗：$($_.Exception.Message)"
    }
}

function Find-BurnInTestExe {
    $fromProcess = Get-BurnInProcesses | Select-Object -First 1 -ExpandProperty Path
    if ($fromProcess -and (Test-Path -LiteralPath $fromProcess)) { return $fromProcess }
    $candidates = @(
        'C:\Program Files\BurnInTest\bit.exe',
        'C:\Program Files (x86)\BurnInTest\bit.exe',
        'C:\Program Files\BurnInTest\bit32.exe'
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Get-BurnInProcesses {
    return @(Get-Process -Name 'bit','bit32' -ErrorAction SilentlyContinue)
}

function Close-BurnInForSettings {
    param([object[]]$Processes)
    foreach ($process in $Processes) {
        $process.Refresh()
        if ($process.HasExited) { continue }
        if (!$process.CloseMainWindow() -or !$process.WaitForExit(20000)) {
            throw 'BurnInTest 尚未正常關閉。請完成目前的測試或處理確認視窗，再重新寫入。'
        }
    }
}

function Save-PairState {
    param($Mode, $Nics, $LocalIp, $DestIp, $Pairs)
    $rows = @()
    foreach ($nic in $Nics) {
        $id = [int]$nic.IfIndex
        $dest = $null
        if ($DestIp -and $DestIp.ContainsKey($id)) { $dest = [string]$DestIp[$id] }
        $rows += ,[pscustomobject]@{
            IfIndex = $id
            Alias = $nic.Alias
            Mac = $nic.Mac
            LocalIp = [string]$LocalIp[$id]
            DestIp = $dest
        }
    }
    $pairRows = @()
    foreach ($p in @($Pairs)) {
        if ($null -eq $p) { continue }
        # 防呆：不要把多對誤收成一個物件後做成員列舉
        if ($p -is [System.Array]) { continue }
        $aAlias = $null
        $bAlias = $null
        if ($p.PSObject.Properties['A']) {
            if ($p.A -and $p.A.PSObject.Properties['Alias']) { $aAlias = [string]$p.A.Alias }
            elseif ($p.A -is [string]) { $aAlias = [string]$p.A }
        }
        if ($p.PSObject.Properties['B']) {
            if ($p.B -and $p.B.PSObject.Properties['Alias']) { $bAlias = [string]$p.B.Alias }
            elseif ($p.B -is [string]) { $bAlias = [string]$p.B }
        }
        if ($aAlias -and $bAlias) {
            $pairRows += ,[pscustomobject]@{ A = $aAlias; B = $bAlias }
        }
    }
    [pscustomobject]@{
        Mode = $Mode
        SavedAt = (Get-Date).ToString('s')
        Nics = $rows
        Pairs = $pairRows
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $StatePath -Encoding UTF8
}

function Write-BurnInBitsFile {
    param([object[]]$NicRows, [bool]$HasPairing)
    # BurnInTest Preferences → Network 最多約 20 列；多寫的舊位址必須清掉
    $maxSlots = 20
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('LOG "BurnInLanPair write network prefs"')
    if ($HasPairing) {
        # 列順序必須對齊系統網卡順序；沒對端的列留空，避免錯位
        $row = 1
        foreach ($n in $NicRows) {
            if ($n.DestIp) {
                $lines.Add(('SETNETWORK ADD{0} "{1}"' -f $row, $n.DestIp))
            }
            else {
                $lines.Add(('SETNETWORK ADD{0} ""' -f $row))
            }
            $row++
        }
        for ($i = $row; $i -le $maxSlots; $i++) {
            $lines.Add(('SETNETWORK ADD{0} ""' -f $i))
        }
        $lines.Add('SETDURATION 0')
        $lines.Add('SETCYCLES 0')
        $lines.Add('SETNETWORK ALL YES')
        $lines.Add('SETDUTYCYCLE NETWORK 100')
        $lines.Add('SETTEST NETWORK')
        if ($SkipCpu) { $lines.Add('UNSETTEST CPU') }
        else { $lines.Add('SETTEST CPU'); $lines.Add('SETDUTYCYCLE CPU 100') }
        if ($SkipMemory) { $lines.Add('UNSETTEST MEMORY') }
        else { $lines.Add('SETTEST MEMORY'); $lines.Add('SETDUTYCYCLE MEMORY 100') }
        $lines.Add('UNSETTEST DISK')
        $lines.Add('SETTEMP AUTO NO')
    }
    [IO.File]::WriteAllLines($BitsPath, $lines.ToArray(), [Text.Encoding]::ASCII)
}



function Initialize-BurnInPreferencesUi {
    if ('BurnInPreferencesMenu' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class BurnInPreferencesMenu
{
    [DllImport("user32.dll")] static extern IntPtr GetMenu(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetSubMenu(IntPtr menu, int index);
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] static extern uint GetMenuItemID(IntPtr menu, int index);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetMenuString(IntPtr menu, uint item, StringBuilder value, int size, uint flags);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wparam, string lparam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wparam, IntPtr lparam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr window);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr window);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr dialog, int id);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    static IntPtr Send(IntPtr window, uint message, IntPtr wparam, IntPtr lparam)
    {
        IntPtr result;
        if (SendMessageTimeout(window,message,wparam,lparam,2,3000,out result)==IntPtr.Zero)
            throw new TimeoutException("BurnInTest did not respond.");
        return result;
    }
    public static bool AllPorts(IntPtr combo, bool apply)
    {
        IntPtr index;
        if (combo == IntPtr.Zero || SendMessageTimeout(combo,0x158,(IntPtr)(-1),
            "All available physical network ports",2,3000,out index)==IntPtr.Zero || index.ToInt32()<0)
            throw new InvalidOperationException("Cannot locate All available physical network ports.");
        if (apply && Send(combo,0x147,IntPtr.Zero,IntPtr.Zero)!=index) {
            Send(combo,0x14e,index,IntPtr.Zero);
            // Programmatic selection needs the same CBN_SELCHANGE as a user selection.
            Send(GetParent(combo),0x111,(IntPtr)((1<<16)|GetDlgCtrlID(combo)),combo);
        }
        return Send(combo,0x147,IntPtr.Zero,IntPtr.Zero)==index;
    }
    // A Windows property sheet can expose its tab strip without accessible tab names.
    // Activate each native page and identify Network by its controls, regardless of order.

    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h,out int pid);
    public static bool Belongs(IntPtr h,int pid) {int owner;GetWindowThreadProcessId(h,out owner);return owner==pid;}
    public static IntPtr FindSheet(int pid)
    {
        IntPtr sheet = IntPtr.Zero;
        while ((sheet = FindWindowEx(IntPtr.Zero, sheet, "#32770", "BurnInTest Preferences")) != IntPtr.Zero)
            if (Belongs(sheet, pid) && IsWindowVisible(sheet)) return sheet;
        return IntPtr.Zero;
    }
    public static bool Visible(IntPtr h) {return IsWindowVisible(h);}
    public static IntPtr NetworkField(IntPtr h,int id) {return GetDlgItem(Send(h,0x476,IntPtr.Zero,IntPtr.Zero),id);}
    public static bool Check(IntPtr sheet, int id, bool apply)
    {
        IntPtr page=Send(sheet,0x476,IntPtr.Zero,IntPtr.Zero);
        IntPtr item=GetDlgItem(page,id);
        if(item==IntPtr.Zero) throw new InvalidOperationException("Missing field "+id);
        if(apply && Send(item,0xf0,IntPtr.Zero,IntPtr.Zero).ToInt32()!=1)
            Send(item,0xf5,IntPtr.Zero,IntPtr.Zero);
        return Send(item,0xf0,IntPtr.Zero,IntPtr.Zero).ToInt32()==1;
    }
    public static void Press(IntPtr sheet,int id)
    {
        IntPtr button=GetDlgItem(sheet,id);
        if(button==IntPtr.Zero || !PostMessage(button,0xf5,IntPtr.Zero,IntPtr.Zero))
            throw new InvalidOperationException("Missing button "+id);
    }
    public static bool SelectNetworkPage(IntPtr sheet)
    {
        IntPtr tabs = FindWindowEx(sheet, IntPtr.Zero, "SysTabControl32", null);
        if (tabs == IntPtr.Zero) return false;
        int count = Send(tabs, 0x1304, IntPtr.Zero, IntPtr.Zero).ToInt32(); // TCM_GETITEMCOUNT
        for (int index = 0; index < count; index++) {
            if (Send(sheet, 0x465, (IntPtr)index, IntPtr.Zero) == IntPtr.Zero) continue; // PSM_SETCURSEL
            IntPtr page = Send(sheet, 0x476, IntPtr.Zero, IntPtr.Zero); // PSM_GETCURRENTPAGEHWND
            if (page != IntPtr.Zero && IsWindowVisible(GetDlgItem(page,1444)) &&
                GetDlgItem(page,1340) != IntPtr.Zero && GetDlgItem(page,1154) != IntPtr.Zero)
                return true;
        }
        return false;
    }
    static int FindPreferences(IntPtr menu, string target)
    {
        for (int i = 0; i < GetMenuItemCount(menu); i++)
        {
            var title = new StringBuilder(256);
            GetMenuString(menu, (uint)i, title, title.Capacity, 0x400);
            string label = title.ToString().Split('\t')[0].Replace("&", "").Trim().TrimEnd('.', '…');
            if (String.Equals(label, target, StringComparison.OrdinalIgnoreCase))
                return (int)GetMenuItemID(menu, i);
            IntPtr sub = GetSubMenu(menu, i);
            if (sub != IntPtr.Zero) {
                int command = FindPreferences(sub, target);
                if (command > 0) return command;
            }
        }
        return -1;
    }
    public static bool Open(IntPtr window, string target = "Test Preferences")
    {
        if (window == IntPtr.Zero || !IsWindowEnabled(window)) return false;
        int command = FindPreferences(GetMenu(window), target);
        return command > 0 && PostMessage(window, 0x111, (IntPtr)command, IntPtr.Zero);
    }
}
'@
}

function Set-BurnInNetworkOptions {
    param([Diagnostics.Process]$Process)
    Initialize-BurnInPreferencesUi
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $opened = $false
    do {
        $Process.Refresh()
        if ($Process.HasExited) { throw 'BurnInTest 已結束，無法寫入網路選項。' }
        $sheet = [BurnInPreferencesMenu]::FindSheet($Process.Id)
        if ($sheet -ne [IntPtr]::Zero) { break }
        if (!$opened) { $opened = [BurnInPreferencesMenu]::Open($Process.MainWindowHandle, 'Test Preferences') }
        Start-Sleep -Milliseconds 150
    } while ($timer.Elapsed.TotalSeconds -lt 20)
    if ($sheet -eq [IntPtr]::Zero) { throw '無法開啟 BurnInTest Preferences，請檢查是否有其他對話框。' }
    try {
        if (![BurnInPreferencesMenu]::SelectNetworkPage($sheet)) { throw '無法辨識 Network 頁面。' }
        if (![BurnInPreferencesMenu]::Check($sheet,1211,$true)) { throw '無法選取 Standard Network Test。' }
        $combo = [BurnInPreferencesMenu]::NetworkField($sheet,1340)
        if (![BurnInPreferencesMenu]::AllPorts($combo,$true)) { throw '無法選取所有實體網路埠。' }
        if (![BurnInPreferencesMenu]::Check($sheet,1444,$true)) { throw '無法勾選 Only use connected cards。' }
        if (![BurnInPreferencesMenu]::Check($sheet,1154,$true)) { throw '無法選取 Bad packet ratio generates error。' }
        [BurnInPreferencesMenu]::Press($sheet,1)
    } catch {
        [BurnInPreferencesMenu]::Press($sheet,2)
        throw
    }
    $timer.Restart()
    while ([BurnInPreferencesMenu]::Visible($sheet)) {
        if ($timer.Elapsed.TotalSeconds -gt 12) { throw 'BurnInTest 尚未接受網路選項。' }
        Start-Sleep -Milliseconds 150
    }
    if ($Process.HasExited) { throw 'BurnInTest 儲存網路選項時結束。' }
}

function Start-ConfiguredBurnIn {
    param([string]$BitExe, [string]$SettingsFile)
    # Confirm that BurnInTest reached the final script command.
    $id = [Guid]::NewGuid().ToString('N')
    $eventName = "Local\BurnInLanPair-$id"
    $ready = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $eventName)
    $launchFile = Join-Path (Split-Path -Parent $SettingsFile) ("lan-prefs-$id.bits")
    try {
        $encoding = [Text.Encoding]::Default
        $commands = [IO.File]::ReadAllLines($SettingsFile, $encoding)
        $shell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        $commands += ('EXECUTE "{0}" -NoProfile -NonInteractive -WindowStyle Hidden -Command "[Threading.EventWaitHandle]::OpenExisting(''{1}'').Set()"' -f $shell,$eventName)
        [IO.File]::WriteAllLines($launchFile, $commands, $encoding)
        $process = Start-Process -FilePath $BitExe -ArgumentList ('-s "{0}"' -f $launchFile) -WorkingDirectory (Split-Path -Parent $BitExe) -PassThru
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (!$ready.WaitOne(250)) {
            if ($process.HasExited -or $timer.Elapsed.TotalSeconds -gt 90) {
                throw 'BurnInTest 未確認載入設定腳本，請查看程式視窗。'
            }
        }
    } finally {
        $ready.Dispose()
        Remove-Item -LiteralPath $launchFile -ErrorAction SilentlyContinue
    }
    Set-BurnInNetworkOptions -Process $process
    return $process
}

function Invoke-WriteBurnIn {
    Write-UiProgress 10 '讀取配對結果'
    $running = @(Get-BurnInProcesses)
    # 沒先開也可以寫：找到 bit.exe 後用 -s 自己啟動並套用，不要求使用者先開。

    if (-not (Test-Path $StatePath)) {
        Write-Output 'RESULT|NO_STATE|還沒有配對結果，請先按「設定與配對」。'
        exit 3
    }

    $state = Get-Content -Raw -Path $StatePath | ConvertFrom-Json
    if ([string]$state.Mode -ne 'Paired') {
        Write-Output 'RESULT|IP_ONLY|上次配對沒有找到網路線。請接好線後再按「設定與配對」。'
        exit 4
    }

    # 依「現在還有 Link」的網卡順序組列，舊的 8 埠狀態不會殘留成 8 列
    Write-UiProgress 30 '比對網卡'
    $live = @(Get-TestNics | Where-Object { -not $_.HasGateway })
    if ($live.Count -lt 1) {
        Write-Output 'RESULT|NO_NIC|找不到已接線的網卡。'
        exit 1
    }

    $byIndex = @{}
    $byAlias = @{}
    $byMac = @{}
    foreach ($n in @($state.Nics)) {
        if ($null -eq $n) { continue }
        try { $byIndex[[int]$n.IfIndex] = $n } catch {}
        if ($n.Alias) { $byAlias[[string]$n.Alias] = $n }
        if ($n.Mac) { $byMac[(Normalize-Mac -Mac ([string]$n.Mac))] = $n }
    }

    $rows = @()
    foreach ($nic in $live) {
        $st = $null
        if ($byIndex.ContainsKey([int]$nic.IfIndex)) { $st = $byIndex[[int]$nic.IfIndex] }
        elseif ($byAlias.ContainsKey([string]$nic.Alias)) { $st = $byAlias[[string]$nic.Alias] }
        else {
            $m = Normalize-Mac -Mac $nic.Mac
            if ($m -and $byMac.ContainsKey($m)) { $st = $byMac[$m] }
        }
        $dest = $null
        if ($st -and $st.DestIp) { $dest = [string]$st.DestIp }
        $rows += ,[pscustomobject]@{
            IfIndex = [int]$nic.IfIndex
            Alias   = [string]$nic.Alias
            DestIp  = $dest
        }
    }

    $withDest = @($rows | Where-Object { $_.DestIp })
    if ($withDest.Count -lt 1) {
        Write-Output 'RESULT|IP_ONLY|目前接著的網卡沒有配對結果，請再按一次「設定與配對」。'
        exit 4
    }

    Write-Host ("將覆寫 BurnInTest 網路目的：{0} 張已連線網卡（有對端 {1} 張），並清空其餘欄位。" -f $rows.Count, $withDest.Count)
    foreach ($r in $rows) {
        if ($r.DestIp) {
            Write-Host ("  {0} -> {1}" -f $r.Alias, $r.DestIp)
        }
        else {
            Write-Host ("  {0} -> （清空）" -f $r.Alias)
        }
    }

    Write-UiProgress 50 '產生 BurnInTest 設定'
    Write-BurnInBitsFile -NicRows $rows -HasPairing $true

    $bitExe = Find-BurnInTestExe
    if (-not $bitExe) {
        Write-Output 'RESULT|NO_BITEXE|找不到 BurnInTest（bit.exe），請確認已安裝。'
        exit 1
    }

    # 必須用 -s 啟動才能套用 SETNETWORK；已開著就先關掉再載入，沒開就直接啟動。不會 RUN。
    Write-UiProgress 75 '開啟 BurnInTest 並載入設定'
    Close-BurnInForSettings -Processes $running
    $null = Start-ConfiguredBurnIn -BitExe $bitExe -SettingsFile $BitsPath

    Write-UiProgress 100 '完成'
    Write-Output ("RESULT|OK|已寫入 {0} 個網路目的 IP。確認後按 GO 開始測試。" -f $withDest.Count)
    exit 0
}

if ($Action -eq 'WriteBurnIn') {
    try {
        Invoke-WriteBurnIn
    } catch {
        Write-Output ("RESULT|ERROR|{0}" -f $_.Exception.Message)
        exit 1
    }
    exit 0
}

# ----- Setup / Full：正確順序 = 先寫 IP → 電源/防火牆 → 最後配對 -----
function Invoke-SetupCore {
    param([bool]$AlsoLaunchBurnInRun)

    # 用本次啟動時剛掃到的有 Link 網卡（拔線後 Down / MediaDisconnected 的不會在裡面）
    if (Test-Path -LiteralPath $StatePath) { Remove-Item -LiteralPath $StatePath -ErrorAction Stop }
    $script:nics = @($script:nics)
    $nics = $script:nics
    Write-Host ''
    Write-Host ("本次可設定網卡 {0} 張（已略過無 Link / 有閘道）：" -f $nics.Count)
    foreach ($nic in $nics) {
        Write-Host ("  {0}  MAC {1}" -f $nic.Alias, $nic.Mac)
    }
    if ($nics.Count -lt 1) {
        throw '沒有可設定的已連線實體網卡（請確認網路線有插上且 Link 有亮）。'
    }

    Write-UiProgress 5 '備份網路設定'
    $backup = @($nics | ForEach-Object { Get-NicSnapshot $_ })
    if (Test-Path -LiteralPath $BackupPath) {
        $archive = Join-Path (Split-Path -Parent $BackupPath) ('ip-backup-{0}.json' -f [Guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $BackupPath -Destination $archive -ErrorAction Stop
    }
    $backup | ConvertTo-Json -Depth 5 | Set-Content -Path $BackupPath -Encoding UTF8

    Enable-IcmpEcho

    # 1) MAC 重複則改寫（失敗不中斷）
    Write-UiProgress 10 '檢查 MAC'
    try {
        $null = Repair-DuplicateMacs -NicList $nics
    } catch {
        Write-Host "MAC 處理略過：$($_.Exception.Message)"
    }

    Write-UiProgress 14 '準備 IP'
    $script:destIp = @{}
    $script:pairs = @()
    $script:pairNote = '已寫入 IP'
    $ipPlan = Build-LocalIpMap -NicList $nics
    if (@($ipPlan.DuplicateMacs).Count -gt 0) {
        throw '測試網卡仍有重複 MAC，請查看紀錄中的網卡名稱與驅動設定。'
    }
    $script:localIp = $ipPlan.Local

    Write-UiProgress 18 '設定 IP'
    $wroteOk = 0
    foreach ($nic in $nics) {
        try {
            Set-StaticIPv4 -IfIndex $nic.IfIndex -IP $script:localIp[[int]$nic.IfIndex] -Prefix 24
            Write-Host ("  {0}  MAC {1}  = {2}" -f $nic.Alias, $nic.Mac, $script:localIp[[int]$nic.IfIndex])
            $wroteOk++
        } catch {
            Write-Host ("  {0} 寫入失敗：{1}" -f $nic.Alias, $_.Exception.Message)
        }
    }
    if ($wroteOk -lt 1) {
        throw '沒有任何網卡成功寫入 IP。'
    }
    Set-TestPortHostMode -Nics $nics
    Write-UiProgress 28 '等待 IP 生效'
    $null = Wait-Ipv4Ready -Nics $nics -AddressByIndex $script:localIp -TimeoutSec 25 -ThrowOnFail

    # 2) 電源 / 防火牆（失敗不中斷設定）
    Write-UiProgress 35 '設定電源與防火牆'
    try {
        Set-BurnInPowerAndFirewall
    } catch {
        Write-Host "電源/防火牆設定略過：$($_.Exception.Message)"
    }

    # 3) 對接＝盡力而為，給 BurnInTest 用；失敗只留 IP，仍算設定成功
    $mode = 'IpOnly'
    $script:pairs = @()
    $script:destIp = @{}
    $allConfiguredNics = @($nics)
    if ($nics.Count -ge 2) {
        Write-UiProgress 45 '偵測網路線'
        try {
            $pairResult = Get-CablePairs -Nics $nics -AddressByIndex $script:localIp
            $found = @()
            if ($pairResult -and $pairResult.PSObject.Properties['Pairs']) {
                $found = @($pairResult.Pairs)
            }
            $ok = $false
            if ($pairResult -and $pairResult.PSObject.Properties['Ok']) {
                $ok = [bool]$pairResult.Ok
            }
            if ($ok -and $found.Count -ge 1) {
                $pairedIdx = @{}
                foreach ($p in $found) {
                    $pairedIdx[[int]$p.A.IfIndex] = $true
                    $pairedIdx[[int]$p.B.IfIndex] = $true
                }
                $pairedNics = @($allConfiguredNics | Where-Object { $pairedIdx.ContainsKey([int]$_.IfIndex) })
                $unpairedNics = @($allConfiguredNics | Where-Object { -not $pairedIdx.ContainsKey([int]$_.IfIndex) })
                if ($pairedNics.Count -eq ($found.Count * 2)) {
                    $script:pairs = $found
                    $plan = Get-AddressPlan -PairList $script:pairs -NicList $pairedNics -LocalMap $script:localIp
                    $script:destIp = $plan.Dest
                    $mode = 'Paired'
                    $script:pairNote = '已依收包分數完成對接配對'
                    Write-Host ("對接成功 {0} 條線（供 BurnInTest）；其餘 {1} 張只留 IP。" -f $found.Count, $unpairedNics.Count)
                    foreach ($nic in $pairedNics) {
                        Write-Host ("  {0} ({1}) -> {2}" -f $nic.Alias, $script:localIp[[int]$nic.IfIndex], $script:destIp[[int]$nic.IfIndex])
                    }
                    foreach ($nic in $unpairedNics) {
                        Write-Host ("  {0} ({1}) 無對端（僅 IP）" -f $nic.Alias, $script:localIp[[int]$nic.IfIndex])
                    }
                    # BurnIn 只認「有對端」的埠：狀態只存成對網卡，避免舊的 8 列殘留
                    $nics = $pairedNics
                    $script:nics = $nics
                    $keepIp = @{}
                    foreach ($nic in $pairedNics) {
                        $keepIp[[int]$nic.IfIndex] = $script:localIp[[int]$nic.IfIndex]
                    }
                    $script:localIp = $keepIp
                }
                else {
                    Write-Host '對接結果不一致，全部只保留 IP。'
                }
            } else {
                Write-Host '未對到夠強的網路線 → 只保留 IP（正常，可再接線後重跑）。'
            }
        } catch {
            throw "網路線探測或還原失敗：$($_.Exception.Message)"
        }
    } else {
        Write-Host ("已連線網卡 {0} 張，不足一對 → 只設定 IP。" -f $nics.Count)
    }

    Save-PairState -Mode $mode -Nics $nics -LocalIp $script:localIp -DestIp $script:destIp -Pairs $script:pairs
    Write-Host ("狀態已儲存：$StatePath （Mode=$mode）")

    # Full 才自動寫入並 RUN；UI 的 Setup 永不自動跑測試
    if ($AlsoLaunchBurnInRun -and $mode -eq 'Paired') {
        Write-UiProgress 95 '寫入 BurnInTest'
        Write-BurnInBitsFile -NicRows @(
            foreach ($nic in $nics) {
                [pscustomobject]@{ DestIp = $script:destIp[[int]$nic.IfIndex]; Alias = $nic.Alias }
            }
        ) -HasPairing $true

        $runPath = Join-Path $OutputDir 'lan-pairs-run.bits'
        $encoding = [Text.Encoding]::Default

        [IO.File]::WriteAllLines($runPath, [string[]]@('RUN CONFIG'), $encoding)

        $bitExe = Find-BurnInTestExe
        if ($bitExe) {
            Close-BurnInForSettings -Processes @(Get-BurnInProcesses)
            $configured = Start-ConfiguredBurnIn -BitExe $bitExe -SettingsFile $BitsPath
            Close-BurnInForSettings -Processes @($configured)
            Start-Process -FilePath $bitExe -ArgumentList ('-s "{0}"' -f $runPath) -WorkingDirectory (Split-Path -Parent $bitExe) | Out-Null
        }
    }

    Write-UiProgress 100 '完成'
    Write-Output ("RESULT|OK|{0}|{1}" -f $mode, @($script:pairs).Count)
}

if ($Action -eq 'Setup') {
    try {
        Invoke-SetupCore -AlsoLaunchBurnInRun $false
        exit 0
    } catch {
        Write-Output ("RESULT|ERROR|{0}" -f $_.Exception.Message)
        Save-ErrorLog -Text $_.Exception.ToString()
        exit 1
    }
}

if ($Action -eq 'Full') {
    try {
        Invoke-SetupCore -AlsoLaunchBurnInRun $true
        if ($env:BURNIN_LAN_NO_PAUSE -ne '1') { Wait-Exit }
        exit 0
    } catch {
        Write-Output ("RESULT|ERROR|{0}" -f $_.Exception.Message)
        Save-ErrorLog -Text $_.Exception.ToString()
        if ($env:BURNIN_LAN_NO_PAUSE -ne '1') { Wait-Exit }
        exit 1
    }
}

Write-Output ("RESULT|ERROR|未知 Action：$Action")
exit 1
}
catch {
    Write-Host ''
    Write-Host '發生錯誤，視窗先留著。'
    Write-Host $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace }
    Save-ErrorLog -Text (@(
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'),
        "OutputDir=$OutputDir",
        $_.Exception.ToString(),
        $_.ScriptStackTrace
    ) -join "`r`n")
    Write-Output ("RESULT|ERROR|{0}" -f $_.Exception.Message)
    if ($env:BURNIN_LAN_NO_PAUSE -ne '1') { Wait-Exit }
    exit 1
}
