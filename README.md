# BurnInLanPair

在同一台 Windows 測試機上，自動辨識用網路線兩兩對接的實體網路埠，設定靜態 IP，並將對端位址寫入 PassMark BurnInTest。工具作者為 Tom24.Du。

## 使用方式

1. 從 [Releases](../../releases) 下載 ZIP，解壓縮到可寫入的資料夾。測試機需另行安裝 BurnInTest，本版針對 10.2 build 1007。
2. 將待測網路埠兩兩接線，以系統管理員權限開啟 BurnInLanPair.exe。
3. 按「設定與配對」，再按「寫入 BurnInTest」。CPU 和 MEM 預設勾選 100%，可以個別取消。
4. 確認 Dashboard 後按 GO。需要查看各埠收發量時，可執行 Check-PortTraffic.cmd。

請在專用測試機上操作。「設定與配對」會修改測試網卡的 IPv4 設定，並調整防火牆及系統電源設定。網卡備份、配對結果和量測紀錄會存放在工具資料夾。

## 從原始碼編譯

在專案根目錄使用 Windows PowerShell 執行：

```powershell
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /optimize+ /win32manifest:src\app.manifest /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /resource:Set-BurnInLanPairs.ps1,BurnInLan.script /out:BurnInLanPair.exe src\Program.cs
```
