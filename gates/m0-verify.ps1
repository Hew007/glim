<#
  M0 门禁自动化验证脚本。
  用法: pwsh -File gates/m0-verify.ps1 [-Exe <path>] [-Memory] [-MemoryMinutes 10]

  覆盖 §8 的 0.1 / 0.1c / 0.2 / 0.3 / 0.4 / 0.5 / 0.6。
  0.1a / 0.1b 需要先占用热键再启动，走 gates/m0-hotkey-conflict.ps1。
#>
param(
  [string]$Exe = "src-tauri/target/release/Glim.exe",
  [switch]$Memory,
  [switch]$MemoryOnly,
  [int]$MemoryMinutes = 10
)
if ($MemoryOnly) { $Memory = $true }

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

public static class W {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtrW(IntPtr h, int index);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr param);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  public delegate bool EnumProc(IntPtr h, IntPtr param);
}
"@

$GWL_EXSTYLE       = -20
$WS_EX_TOOLWINDOW  = 0x00000080
$WS_EX_APPWINDOW   = 0x00040000
$WS_EX_NOACTIVATE  = 0x08000000
$GW_OWNER          = 4
$KEYEVENTF_KEYUP   = 0x0002
$VK_CONTROL = 0x11; $VK_MENU = 0x12; $VK_D = 0x44; $VK_ESCAPE = 0x1B
$MOUSEEVENTF_LEFTDOWN = 0x0002; $MOUSEEVENTF_LEFTUP = 0x0004

function Find-GlimWindow([int]$TargetPid) {
  $script:found = [IntPtr]::Zero
  $cb = [W+EnumProc]{
    param([IntPtr]$h, [IntPtr]$p)
    $owner = [uint32]0
    [void][W]::GetWindowThreadProcessId($h, [ref]$owner)
    if ($owner -eq $TargetPid) {
      $sb = New-Object System.Text.StringBuilder 256
      [void][W]::GetWindowTextW($h, $sb, 256)
      if ($sb.ToString() -eq "Glim") { $script:found = $h; return $false }
    }
    return $true
  }
  [void][W]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:found
}

function Send-Hotkey {
  [W]::keybd_event($VK_CONTROL, 0, 0, [UIntPtr]::Zero)
  [W]::keybd_event($VK_MENU, 0, 0, [UIntPtr]::Zero)
  [W]::keybd_event($VK_D, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 30
  [W]::keybd_event($VK_D, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
  [W]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
  [W]::keybd_event($VK_CONTROL, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
}

function Send-EscapeKey {
  [W]::keybd_event($VK_ESCAPE, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 30
  [W]::keybd_event($VK_ESCAPE, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
}

function Invoke-ClickAt([int]$x, [int]$y) {
  [void][W]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 120
  [W]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [W]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
}

function Get-Rect([IntPtr]$h) {
  $r = New-Object RECT
  [void][W]::GetWindowRect($h, [ref]$r)
  return $r
}

# ---------------------------------------------------------------- 启动
$timingLog = Join-Path $env:APPDATA "glim\hotkey-timing.log"
# 这里不删日志：-MemoryOnly 一次热键都不按，删了就再也不会重建，
# 上一次全量运行的证据会被无声抹掉。清空动作放在 0.1c 段，那里马上就会重新写满。

$exePath = (Resolve-Path $Exe).Path
Get-Process -Name Glim -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
$proc = Start-Process -FilePath $exePath -PassThru
Start-Sleep -Seconds 5

$hwnd = Find-GlimWindow $proc.Id
if ($hwnd -eq [IntPtr]::Zero) { throw "找不到 Glim 面板窗口" }
"窗口句柄 = 0x{0:X}  pid = {1}" -f [int64]$hwnd, $proc.Id

if (-not $MemoryOnly) {

# ---------------------------------------------------------------- 0.2 扩展样式
$ex = [int64][W]::GetWindowLongPtrW($hwnd, $GWL_EXSTYLE)
"[0.2] GWL_EXSTYLE = 0x{0:X8}" -f $ex
"[0.2] WS_EX_TOOLWINDOW = {0}" -f (($ex -band $WS_EX_TOOLWINDOW) -ne 0)
"[0.2] WS_EX_NOACTIVATE = {0}" -f (($ex -band $WS_EX_NOACTIVATE) -ne 0)
"[0.2] WS_EX_APPWINDOW  = {0} (必须为 False，否则 TOOLWINDOW 会被它抵消)" -f (($ex -band $WS_EX_APPWINDOW) -ne 0)

# Alt+Tab 判定规则：可见 且 无 owner 且 (没有 TOOLWINDOW 或 有 APPWINDOW)
# 面板可见时把进程的所有顶层窗口过一遍，确认没有一个进 Alt+Tab。
[void][W]::SetCursorPos(600, 500)
Send-Hotkey
Start-Sleep -Milliseconds 600
$script:altTabCount = 0
$script:windowLines = @()
$enumCb = [W+EnumProc]{
  param([IntPtr]$h, [IntPtr]$p)
  $owner = [uint32]0
  [void][W]::GetWindowThreadProcessId($h, [ref]$owner)
  if ($owner -eq $proc.Id) {
    $title = New-Object System.Text.StringBuilder 256
    [void][W]::GetWindowTextW($h, $title, 256)
    $cls = New-Object System.Text.StringBuilder 256
    [void][W]::GetClassNameW($h, $cls, 256)
    $e = [int64][W]::GetWindowLongPtrW($h, $GWL_EXSTYLE)
    $vis = [W]::IsWindowVisible($h)
    $hasOwner = ([W]::GetWindow($h, $GW_OWNER) -ne [IntPtr]::Zero)
    $inAltTab = $vis -and (-not $hasOwner) -and ((($e -band $WS_EX_TOOLWINDOW) -eq 0) -or (($e -band $WS_EX_APPWINDOW) -ne 0))
    if ($inAltTab) { $script:altTabCount++ }
    $script:windowLines += ("    class='{0}' title='{1}' visible={2} ex=0x{3:X8} hasOwner={4} 进AltTab={5}" -f $cls, $title, $vis, $e, $hasOwner, $inAltTab)
  }
  return $true
}
[void][W]::EnumWindows($enumCb, [IntPtr]::Zero)
"[0.2] 面板可见时进程内的顶层窗口："
$script:windowLines
"[0.2] 进 Alt+Tab 的窗口数 = $script:altTabCount (期望 0)"
Send-Hotkey
Start-Sleep -Milliseconds 400

# ---------------------------------------------------------------- 0.1 / 0.1c
# 0.2 那次 show 也会记一笔采样，清空后重新采，保证正好 20 个样本
Remove-Item $timingLog -ErrorAction SilentlyContinue
[void][W]::SetCursorPos(600, 500)
$toggleOk = $true
for ($i = 1; $i -le 20; $i++) {
  Send-Hotkey
  Start-Sleep -Milliseconds 300
  if (-not [W]::IsWindowVisible($hwnd)) { $toggleOk = $false; "  第 $i 次 show 后窗口不可见" }
  Send-Hotkey
  Start-Sleep -Milliseconds 300
  if ([W]::IsWindowVisible($hwnd)) { $toggleOk = $false; "  第 $i 次 toggle 后窗口仍可见" }
}
"[0.1c] toggle 20 轮全部正确 = $toggleOk"

# 相位一旦被一次计划外的 hide 打乱，之后每一轮都会报错，光看 $toggleOk
# 分不清是产品 bug 还是跑的时候碰了鼠标。把非 toggle 的 hide 原因直接列出来。
$strayHides = @(Get-Content $timingLog -ErrorAction SilentlyContinue |
  Where-Object { $_ -match '^\[hide\]' -and $_ -notmatch 'hotkey-toggle' })
if ($strayHides.Count -gt 0) {
  "[0.1c] 计划外 hide $($strayHides.Count) 次（toggle 相位被打乱的原因）："
  $strayHides | ForEach-Object { "    $_" }
} else {
  "[0.1c] 计划外 hide = 0"
}

$samples = @(Get-Content $timingLog | ForEach-Object { if ($_ -match '#(\d+) (\d+)us') { [int]$Matches[2] } })
"[0.1] 采样数 = $($samples.Count)（期望 20；多出来的每一个都对应一次计划外 hide）"
if ($samples.Count -gt 0) {
  $sorted = $samples | Sort-Object
  $p95Index = [Math]::Ceiling(0.95 * $sorted.Count) - 1
  "[0.1] min={0:N2}ms median={1:N2}ms p95={2:N2}ms max={3:N2}ms" -f `
    ($sorted[0]/1000), ($sorted[[int]($sorted.Count/2)]/1000), ($sorted[$p95Index]/1000), ($sorted[-1]/1000)
}

# ---------------------------------------------------------------- 0.3 不夺焦点
# Win11 记事本会恢复上次的标签页，裸开会把旧文档的内容一起算进来
# （实测拿到的是 hosts 文件的首行，而不是本次输入）。指定一个空临时文件。
$npFile = Join-Path $env:TEMP ("glim-m0-{0}.txt" -f [guid]::NewGuid())
Set-Content -LiteralPath $npFile -Value "" -NoNewline
$np = Start-Process notepad -ArgumentList $npFile -PassThru
Start-Sleep -Seconds 3
[System.Windows.Forms.SendKeys]::SendWait("123")
Start-Sleep -Milliseconds 500
$fgBefore = [W]::GetForegroundWindow()
[void][W]::SetCursorPos(700, 400)
Send-Hotkey
Start-Sleep -Milliseconds 600
$fgAfter = [W]::GetForegroundWindow()
[System.Windows.Forms.SendKeys]::SendWait("456")
Start-Sleep -Milliseconds 500
"[0.3] 前台窗口未变 = {0} (before=0x{1:X} after=0x{2:X})" -f ($fgBefore -eq $fgAfter), [int64]$fgBefore, [int64]$fgAfter
"[0.3] 面板可见 = {0}" -f [W]::IsWindowVisible($hwnd)
[System.Windows.Forms.SendKeys]::SendWait("^a")
Start-Sleep -Milliseconds 300
[System.Windows.Forms.SendKeys]::SendWait("^c")
Start-Sleep -Milliseconds 600
$typed = Get-Clipboard
"[0.3] 记事本内容 = '{0}' (期望 123456)" -f ($typed -replace "`r|`n", "")

# 面板截图存档（骨架屏确实渲染）
Add-Type -AssemblyName System.Drawing
$r = Get-Rect $hwnd
$bmp = New-Object System.Drawing.Bitmap (($r.Right - $r.Left), ($r.Bottom - $r.Top))
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
$shot = Join-Path (Split-Path $PSScriptRoot -Parent) "gates\M0-panel.png"
$bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"[截图] 面板已存到 $shot"

# ---------------------------------------------------------------- 0.4 Esc
Send-EscapeKey
Start-Sleep -Milliseconds 600
"[0.4] Esc 后隐藏 = {0}" -f (-not [W]::IsWindowVisible($hwnd))

# ---------------------------------------------------------------- 0.4 点击外部
[void][W]::SetCursorPos(700, 400)
Send-Hotkey
Start-Sleep -Milliseconds 600
$visBefore = [W]::IsWindowVisible($hwnd)
Invoke-ClickAt 60 900
Start-Sleep -Milliseconds 600
"[0.4] 点击外部: 之前可见={0} 之后隐藏={1}" -f $visBefore, (-not [W]::IsWindowVisible($hwnd))

[void][W]::SetCursorPos(700, 400)
Send-Hotkey
Start-Sleep -Milliseconds 600
$r = Get-Rect $hwnd
Invoke-ClickAt ([int](($r.Left + $r.Right)/2)) ([int](($r.Top + $r.Bottom)/2))
Start-Sleep -Milliseconds 600
"[0.4] 点击窗口内部仍可见 = {0}" -f [W]::IsWindowVisible($hwnd)
Send-EscapeKey
Start-Sleep -Milliseconds 400

$np | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $npFile -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- 0.5 多屏四角
"[0.5] 多显示器四角定位"
foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
  $wa = $screen.WorkingArea
  $corners = @(
    @{ name = "左上"; x = $wa.Left + 5;  y = $wa.Top + 5 },
    @{ name = "右上"; x = $wa.Right - 5; y = $wa.Top + 5 },
    @{ name = "左下"; x = $wa.Left + 5;  y = $wa.Bottom - 5 },
    @{ name = "右下"; x = $wa.Right - 5; y = $wa.Bottom - 5 }
  )
  foreach ($c in $corners) {
    [void][W]::SetCursorPos($c.x, $c.y)
    Start-Sleep -Milliseconds 200
    Send-Hotkey
    Start-Sleep -Milliseconds 500
    $r = Get-Rect $hwnd
    $inside = ($r.Left -ge $wa.Left) -and ($r.Top -ge $wa.Top) -and ($r.Right -le $wa.Right) -and ($r.Bottom -le $wa.Bottom)
    "  {0} {1} 光标=({2},{3}) 窗口=({4},{5})-({6},{7}) 在工作区内={8}" -f `
      $screen.DeviceName, $c.name, $c.x, $c.y, $r.Left, $r.Top, $r.Right, $r.Bottom, $inside
    Send-Hotkey
    Start-Sleep -Milliseconds 400
  }
}

}  # end if (-not $MemoryOnly)

# ---------------------------------------------------------------- 0.6 内存
# Chromium 多进程的 WorkingSet 会把共享页在每个进程里重复计一遍，
# 直接相加会得到虚高的数字。任务管理器显示的是「专用工作集」，
# 这里按同一口径取 WorkingSetPrivate，并按父进程链认自己的 WebView2 子进程。
function Get-GlimMemory([int]$RootPid) {
  $all = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'"
  $ours = @()
  $frontier = @($RootPid)
  while ($frontier.Count -gt 0) {
    $next = @()
    foreach ($p in $all) {
      if ($frontier -contains [int]$p.ParentProcessId -and $ours.ProcessId -notcontains $p.ProcessId) {
        $ours += $p; $next += [int]$p.ProcessId
      }
    }
    $frontier = $next
  }
  $perf = Get-CimInstance Win32_PerfRawData_PerfProc_Process
  $ids = @($RootPid) + @($ours.ProcessId)
  $private = 0; $working = 0
  foreach ($id in $ids) {
    $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
    if (-not $proc) { continue }
    $working += $proc.WorkingSet64
    $row = $perf | Where-Object { $_.IDProcess -eq $id }
    if ($row) { $private += [int64]$row.WorkingSetPrivate }
  }
  return [pscustomobject]@{
    PrivateMB = [Math]::Round($private / 1MB, 1)
    WorkingMB = [Math]::Round($working / 1MB, 1)
    Children  = $ours.Count
  }
}

if ($Memory) {
  "[0.6] 内存采样 $MemoryMinutes 分钟（glim.exe + 其 WebView2 子进程）"
  $end = (Get-Date).AddMinutes($MemoryMinutes)
  $peakPrivate = 0; $peakWorking = 0
  while ((Get-Date) -lt $end) {
    if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) { break }
    $m = Get-GlimMemory $proc.Id
    if ($m.PrivateMB -gt $peakPrivate) { $peakPrivate = $m.PrivateMB }
    if ($m.WorkingMB -gt $peakWorking) { $peakWorking = $m.WorkingMB }
    "  {0:HH:mm:ss} 专用工作集 {1} MB / 总工作集 {2} MB（WebView2 子进程 {3} 个）" -f (Get-Date), $m.PrivateMB, $m.WorkingMB, $m.Children
    Start-Sleep -Seconds 60
  }
  "[0.6] 峰值：专用工作集 $peakPrivate MB（任务管理器口径，门禁阈值 80MB）"
  "[0.6] 峰值：总工作集 $peakWorking MB（含 Chromium 共享页重复计入，仅供参考）"
}

if (-not $MemoryOnly) {
  $archived = Join-Path (Split-Path $PSScriptRoot -Parent) "gates\M0-timing.log"
  Copy-Item $timingLog $archived -Force
  "已归档到: $archived"
}
"完成。原始延迟日志: $timingLog"
