<#
  占住 Ctrl+Alt+D，用于门禁 0.1a。由 m0-hotkey-conflict.ps1 拉起。
  RegisterHotKey 的占用绑定在调用线程上，所以进程活着就一直占着。
#>
param([int]$Seconds = 180, [string]$StatusFile)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class H {
  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
}
"@

$MOD_ALT = 0x0001
$MOD_CONTROL = 0x0002
$VK_D = 0x44

$ok = [H]::RegisterHotKey([IntPtr]::Zero, 1, ($MOD_ALT -bor $MOD_CONTROL), $VK_D)
$err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
if ($StatusFile) { "registered=$ok lastError=$err" | Set-Content -Path $StatusFile -Encoding utf8 }
Start-Sleep -Seconds $Seconds
