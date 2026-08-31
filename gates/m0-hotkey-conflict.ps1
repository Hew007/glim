<#
  M0 门禁 0.1a / 0.1b 验证脚本。
  用法: pwsh -File gates/m0-hotkey-conflict.ps1 [-Exe <path>]

  0.1a  先用另一个进程 RegisterHotKey 占住 Ctrl+Alt+D，再启动 Glim，
        验证启动即弹出提示窗口（而不是静默失败）。
  0.1b  在提示窗口里把热键改成 Ctrl+Alt+G，验证不重启即刻生效，
        且旧热键 Ctrl+Alt+D 不再响应。
#>
param(
  [string]$Exe = "src-tauri/target/release/Glim.exe"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
public static class K {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr param);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  public delegate bool EnumProc(IntPtr h, IntPtr param);
}
"@

$KEYEVENTF_KEYUP = 0x0002
$VK_CONTROL = 0x11; $VK_MENU = 0x12; $VK_D = 0x44; $VK_G = 0x47
$MOUSEEVENTF_LEFTDOWN = 0x0002; $MOUSEEVENTF_LEFTUP = 0x0004

function Invoke-ClickAt([int]$x, [int]$y) {
  [void][K]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 150
  [K]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [K]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 250
}

function Find-GlimWindow([int]$TargetPid) {
  $script:found = [IntPtr]::Zero
  $cb = [K+EnumProc]{
    param([IntPtr]$h, [IntPtr]$p)
    $owner = [uint32]0
    [void][K]::GetWindowThreadProcessId($h, [ref]$owner)
    if ($owner -eq $TargetPid) {
      $sb = New-Object System.Text.StringBuilder 256
      [void][K]::GetWindowTextW($h, $sb, 256)
      if ($sb.ToString() -eq "Glim") { $script:found = $h; return $false }
    }
    return $true
  }
  [void][K]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:found
}

function Send-Combo([int]$vk) {
  [K]::keybd_event($VK_CONTROL, 0, 0, [UIntPtr]::Zero)
  [K]::keybd_event($VK_MENU, 0, 0, [UIntPtr]::Zero)
  [K]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 30
  [K]::keybd_event($vk, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
  [K]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
  [K]::keybd_event($VK_CONTROL, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
}

# ------------------------------------------------ 复位到默认状态
$settingsPath = Join-Path $env:APPDATA "glim\settings.json"
Remove-Item $settingsPath -ErrorAction SilentlyContinue
Get-Process -Name Glim -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

# ------------------------------------------------ 0.1a 先占住 Ctrl+Alt+D
$statusFile = Join-Path ([System.IO.Path]::GetTempPath()) "glim-occupy-status.txt"
Remove-Item $statusFile -ErrorAction SilentlyContinue
$occupyScript = Join-Path $PSScriptRoot "m0-occupy-hotkey.ps1"
$occupier = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
  "-NoProfile", "-File", $occupyScript, "-Seconds", "180", "-StatusFile", $statusFile
)
Start-Sleep -Seconds 4
$status = if (Test-Path $statusFile) { (Get-Content $statusFile -Raw).Trim() } else { "(占用进程没写出状态)" }
"[0.1a] 占用进程 pid = $($occupier.Id)  $status"
if ($status -notlike "registered=True*") {
  throw "占用 Ctrl+Alt+D 失败，0.1a 无法验证：$status"
}
$exePath = (Resolve-Path $Exe).Path
$proc = Start-Process -FilePath $exePath -PassThru
Start-Sleep -Seconds 6

$hwnd = Find-GlimWindow $proc.Id
if ($hwnd -eq [IntPtr]::Zero) { throw "找不到 Glim 面板窗口" }
$visible = [K]::IsWindowVisible($hwnd)
"[0.1a] 启动后面板自动可见（冲突提示）= $visible"
if (-not $visible) {
  "[0.1a] 未通过：注册失败但没有提示"
}

# ------------------------------------------------ 0.1b 当场改键为 Ctrl+Alt+G
$rect = New-Object RECT
[void][K]::GetWindowRect($hwnd, [ref]$rect)
"[0.1b] 提示窗口矩形 = ($($rect.Left),$($rect.Top))-($($rect.Right),$($rect.Bottom))"
"[0.1b] 提示窗口已是前台 = $([K]::GetForegroundWindow() -eq $hwnd)"

Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap (($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
function Save-PanelShot([string]$name) {
  $r = New-Object RECT
  [void][K]::GetWindowRect($hwnd, [ref]$r)
  $b = New-Object System.Drawing.Bitmap (($r.Right - $r.Left), ($r.Bottom - $r.Top))
  $gr = [System.Drawing.Graphics]::FromImage($b)
  $gr.CopyFromScreen($r.Left, $r.Top, 0, 0, $b.Size)
  $path = Join-Path $PSScriptRoot $name
  $b.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $gr.Dispose(); $b.Dispose()
  return $path
}
$shot = Join-Path $PSScriptRoot "M0-hotkey-conflict.png"
$bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"[0.1b] 冲突提示截图 = $shot"

# 点进输入框再打字：提示窗口这一路径是可聚焦的（临时摘掉 NOACTIVATE）。
# 坐标按 M0-hotkey-conflict.png 实测：输入框在窗口内 y≈121，按钮在 x≈240。
"[0.1b] 点击前可见 = $([K]::IsWindowVisible($hwnd))"
Invoke-ClickAt ($rect.Left + 50) ($rect.Top + 121)
$after = New-Object RECT
[void][K]::GetWindowRect($hwnd, [ref]$after)
"[0.1b] 点击点 = ($($rect.Left + 50),$($rect.Top + 121))  点击时窗口矩形 = ($($after.Left),$($after.Top))-($($after.Right),$($after.Bottom))"
"[0.1b] 点击后可见 = $([K]::IsWindowVisible($hwnd))  成为前台 = $([K]::GetForegroundWindow() -eq $hwnd)"
[System.Windows.Forms.SendKeys]::SendWait("^a")
Start-Sleep -Milliseconds 300
[System.Windows.Forms.SendKeys]::SendWait("Ctrl{+}Alt{+}G")
Start-Sleep -Milliseconds 600
# 中文输入法会把这串字母留在合成态，候选条不关掉的话第一次点击会被 IME 吃掉
[System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
Start-Sleep -Milliseconds 400
"[0.1b] 打字后截图 = $(Save-PanelShot 'M0-hotkey-typed.png')"
Invoke-ClickAt ($rect.Left + 240) ($rect.Top + 121)
Start-Sleep -Milliseconds 400
if ([K]::IsWindowVisible($hwnd)) { Invoke-ClickAt ($rect.Left + 240) ($rect.Top + 121) }
Start-Sleep -Seconds 2
if ([K]::IsWindowVisible($hwnd)) { "[0.1b] 点按钮后截图 = $(Save-PanelShot 'M0-hotkey-after-save.png')" }

$saved = if (Test-Path $settingsPath) { (Get-Content $settingsPath -Raw).Trim() -replace "\s+", " " } else { "(无文件)" }
"[0.1b] settings.json = $saved"
$hiddenAfterSave = -not [K]::IsWindowVisible($hwnd)
"[0.1b] 保存后面板已隐藏 = $hiddenAfterSave"

if (-not $hiddenAfterSave) {
  "[0.1b] 面板未隐藏，无法用可见性判断热键是否生效 —— 后续结论不成立"
} else {
  [void][K]::SetCursorPos(700, 400)
  Send-Combo $VK_G
  Start-Sleep -Milliseconds 900
  "[0.1b] 新热键 Ctrl+Alt+G 生效（未重启）= $([K]::IsWindowVisible($hwnd))"
  Send-Combo $VK_G
  Start-Sleep -Milliseconds 700

  Send-Combo $VK_D
  Start-Sleep -Milliseconds 900
  "[0.1b] 旧热键 Ctrl+Alt+D 已不再触发 = $(-not [K]::IsWindowVisible($hwnd))"
}

# ------------------------------------------------ 收尾
$proc | Stop-Process -Force -ErrorAction SilentlyContinue
$occupier | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item $settingsPath -ErrorAction SilentlyContinue
"完成，已复位 settings.json"
