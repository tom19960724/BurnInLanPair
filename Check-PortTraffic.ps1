#Requires -Version 5.1
param([ValidateRange(1,120)][int]$Seconds = 10)
$ErrorActionPreference = 'Stop'
$state = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'lan-pair-state.json') | ConvertFrom-Json
if ($state.Mode -ne 'Paired') { throw '請先完成網路線配對。' }

function Get-PortSample {
    $sample = @{}
    foreach ($nic in @($state.Nics)) {
        $adapter = Get-NetAdapter -InterfaceIndex $nic.IfIndex -ErrorAction Stop
        if ($adapter.MacAddress -ne $nic.Mac -or $adapter.Status -ne 'Up') {
            throw ("{0} 的網卡身分或連線狀態已改變，請重新配對。" -f $nic.Alias)
        }
        $stats = $adapter | Get-NetAdapterStatistics -ErrorAction Stop
        if ($null -eq $stats.ReceivedBytes -or $null -eq $stats.SentBytes) {
            throw ("無法取得 {0} 的收送計數。" -f $nic.Alias)
        }
        $sample[[int]$nic.IfIndex] = [pscustomobject]@{
            Rx = [decimal]$stats.ReceivedBytes
            Tx = [decimal]$stats.SentBytes
            Time = [Diagnostics.Stopwatch]::GetTimestamp()
        }
    }
    return $sample
}

Write-Host ("正在量測已配對網路埠，約 {0} 秒。" -f $Seconds)
$before = Get-PortSample
Start-Sleep -Seconds $Seconds
$after = Get-PortSample
$rows = foreach ($nic in @($state.Nics)) {
    $id = [int]$nic.IfIndex
    $secondsElapsed = ($after[$id].Time - $before[$id].Time) / [double][Diagnostics.Stopwatch]::Frequency
    $rx = $after[$id].Rx - $before[$id].Rx
    $tx = $after[$id].Tx - $before[$id].Tx
    if ($rx -lt 0 -or $tx -lt 0) { throw ("{0} 的網卡計數器已重設，請重新量測。" -f $nic.Alias) }
    [pscustomobject]@{
        Port = $nic.Alias
        LocalIP = $nic.LocalIp
        PeerIP = $nic.DestIp
        RxBytes = $rx
        TxBytes = $tx
        RxMbps = [Math]::Round([double]$rx * 8 / $secondsElapsed / 1e6, 4)
        TxMbps = [Math]::Round([double]$tx * 8 / $secondsElapsed / 1e6, 4)
    }
}
$rows | Format-Table -AutoSize
$report = Join-Path $PSScriptRoot 'port-traffic.csv'
$rows | Export-Csv -LiteralPath $report -NoTypeInformation -Encoding UTF8
Write-Host ("量測結果：{0}" -f $report)
