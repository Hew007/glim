<#
  M1 门禁自动化验证脚本。
  用法: pwsh -File gates/m1-verify.ps1 [-Exe <path>] [-Runs 10] [-Only 1.2]

  覆盖 §8 的 1.1 / 1.2 / 1.3 / 1.4 / 1.5 / 1.6 / 1.7。

  与 M0 的关键区别：M1 的门禁大多是「面板里显示了什么」，而面板内容在
  WebView 里，PowerShell 读不到 DOM。因此断言的是 Rust 侧写进
  %APPDATA%\glim\hotkey-timing.log 的判定结果（[req:error] kind=…），
  它记录的正是产生那段界面文案的那个决策。

  1.3 / 1.4 会临时改写 settings.json（改端点、改 provider id），
  跑完无条件还原。中途 Ctrl+C 的话手动检查该文件。
#>
param(
  [string]$Exe = "src-tauri/target/release/Glim.exe",
  [int]$Runs = 10,
  [string]$Only = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class M1 {
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr param);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  public delegate bool EnumProc(IntPtr h, IntPtr param);
}
"@

$KEYEVENTF_KEYUP = 0x0002
$VK_CONTROL = 0x11; $VK_MENU = 0x12; $VK_D = 0x44; $VK_ESCAPE = 0x1B

$logPath      = Join-Path $env:APPDATA "glim\hotkey-timing.log"
$settingsPath = Join-Path $env:APPDATA "glim\settings.json"

function Send-Hotkey {
  [M1]::keybd_event($VK_CONTROL, 0, 0, [UIntPtr]::Zero)
  [M1]::keybd_event($VK_MENU, 0, 0, [UIntPtr]::Zero)
  [M1]::keybd_event($VK_D, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 30
  [M1]::keybd_event($VK_D, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
  [M1]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
  [M1]::keybd_event($VK_CONTROL, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
}

function Send-Escape {
  [M1]::keybd_event($VK_ESCAPE, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 30
  [M1]::keybd_event($VK_ESCAPE, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
}

function Find-GlimWindow([int]$TargetPid) {
  $script:found = [IntPtr]::Zero
  $cb = [M1+EnumProc]{
    param([IntPtr]$h, [IntPtr]$p)
    $owner = [uint32]0
    [void][M1]::GetWindowThreadProcessId($h, [ref]$owner)
    if ($owner -eq $TargetPid) {
      $sb = New-Object System.Text.StringBuilder 256
      [void][M1]::GetWindowTextW($h, $sb, 256)
      if ($sb.ToString() -eq "Glim") { $script:found = $h; return $false }
    }
    return $true
  }
  [void][M1]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:found
}

function Start-Glim {
  Get-Process -Name Glim -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Milliseconds 800
  $p = Start-Process -FilePath (Resolve-Path $Exe).Path -PassThru
  Start-Sleep -Seconds 5
  return $p
}

function Stop-Glim($proc) {
  if ($proc) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 500
}

function Clear-Log { Remove-Item $logPath -ErrorAction SilentlyContinue }

function Get-Log {
  if (Test-Path $logPath) { Get-Content $logPath } else { @() }
}

# 等日志里出现某个模式，或超时。轮询而不是死等固定秒数，
# 因为实测首字节延迟在 868ms 到 61s 之间漂移，写死等待时间必然误判。
function Wait-ForLog([string]$Pattern, [int]$TimeoutSeconds = 25) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $hit = Get-Log | Where-Object { $_ -match $Pattern }
    if ($hit) { return $hit[-1] }
    Start-Sleep -Milliseconds 250
  }
  return $null
}

function Should-Run([string]$Id) {
  return (-not $Only) -or ($Only -eq $Id)
}

# settings.json 的临时改写与还原。1.3 / 1.4 要靠它制造故障条件。
$script:settingsBackup = $null
function Backup-Settings {
  if (Test-Path $settingsPath) { $script:settingsBackup = Get-Content $settingsPath -Raw }
}
function Restore-Settings {
  if ($script:settingsBackup) {
    Set-Content -LiteralPath $settingsPath -Value $script:settingsBackup -Encoding UTF8 -NoNewline
  }
}
function Edit-Settings([scriptblock]$Change) {
  $s = Get-Content $settingsPath -Raw | ConvertFrom-Json
  & $Change $s
  $s | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
}

if (-not (Test-Path $settingsPath)) {
  throw "找不到 $settingsPath —— 先启动一次 Glim，或跑 tools/models.ps1 -Set <模型>。"
}
Backup-Settings

$results = @()
function Record([string]$Id, [bool]$Pass, [string]$Detail) {
  $mark = if ($Pass) { "通过" } else { "未通过" }
  "[$Id] $mark — $Detail"
  $script:results += [pscustomobject]@{ 编号 = $Id; 结果 = $mark; 实测 = $Detail }
}

try {

# ================================================================ 1.1 / 1.2
# 复制英文段落 → 热键 → 中文流式输出；首字符延迟 p50 < 1200ms
if ((Should-Run "1.1") -or (Should-Run "1.2")) {
  "=== 1.1 / 1.2：翻译与首字符延迟（$Runs 次）==="
  $proc = Start-Glim
  $hwnd = Find-GlimWindow $proc.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "找不到 Glim 面板窗口" }
  Clear-Log

  $samples = @()
  $chunkCounts = @()
  for ($i = 1; $i -le $Runs; $i++) {
    # 每次换一句，避免服务端缓存掩盖真实延迟
    Set-Clipboard -Value "The quick brown fox jumps over the lazy dog. Attempt number $i."
    Start-Sleep -Milliseconds 300
    Send-Hotkey
    $done = Wait-ForLog "\[req:done\] request=\d+ chunks=\d+" 30
    if (-not $done) { "  第 $i 次：超时或失败" }
    Send-Escape
    Start-Sleep -Milliseconds 600
  }

  foreach ($line in Get-Log) {
    if ($line -match '\[first-chunk\] (\d+)us') { $samples += ([double]$Matches[1] / 1000) }
    if ($line -match '\[req:done\] request=\d+ chunks=(\d+)') { $chunkCounts += [int]$Matches[1] }
  }

  # 1.1：出了译文且是分多次送达的，才算「流式」
  $streamed = @($chunkCounts | Where-Object { $_ -ge 2 }).Count
  Record "1.1" ($chunkCounts.Count -gt 0 -and $streamed -gt 0) `
    "完成 $($chunkCounts.Count)/$Runs 次，其中 $streamed 次的增量条数 >= 2（证明是流式而非一次性返回）。译文正确性需人工核对截图。"

  if ($samples.Count -gt 0) {
    $sorted = $samples | Sort-Object
    $p50 = $sorted[[int]($sorted.Count / 2)]
    $detail = "样本 $($samples.Count)/$Runs，最小 $([math]::Round($sorted[0])) ms，中位 $([math]::Round($p50)) ms，最大 $([math]::Round($sorted[-1])) ms（阈值 1200ms）"
    Record "1.2" ($samples.Count -ge 10 -and $p50 -lt 1200) $detail
    "  原始值：" + (($sorted | ForEach-Object { [math]::Round($_) }) -join ", ")
  } else {
    Record "1.2" $false "一个样本都没采到"
  }
  Stop-Glim $proc
}

# ================================================================ 1.6
# 剪贴板为空 / 为图片 → 友好提示
if (Should-Run "1.6") {
  "=== 1.6：剪贴板无文本 ==="
  $proc = Start-Glim
  Clear-Log

  # 图片
  $bmp = New-Object System.Drawing.Bitmap 16, 16
  [System.Windows.Forms.Clipboard]::SetImage($bmp)
  Start-Sleep -Milliseconds 400
  Send-Hotkey
  $imageHit = Wait-ForLog "\[req:error\] kind=EmptyClipboard" 10
  Send-Escape
  Start-Sleep -Milliseconds 600

  # 纯空白
  Set-Clipboard -Value "   `t  "
  Start-Sleep -Milliseconds 400
  Send-Hotkey
  $blankHit = Wait-ForLog "\[req:error\] kind=EmptyClipboard" 10
  Send-Escape

  Record "1.6" ($null -ne $imageHit -and $null -ne $blankHit) `
    "图片：$(if ($imageHit) { '判定为 EmptyClipboard' } else { '未命中' })；纯空白：$(if ($blankHit) { '判定为 EmptyClipboard' } else { '未命中' })"
  $bmp.Dispose()
  Stop-Glim $proc
}

# ================================================================ 1.7
# 超过 5000 字符 → TooLong，不静默截断
if (Should-Run "1.7") {
  "=== 1.7：超长输入 ==="
  $proc = Start-Glim
  Clear-Log

  Set-Clipboard -Value ("a" * 5001)
  Start-Sleep -Milliseconds 400
  Send-Hotkey
  $hit = Wait-ForLog "\[req:error\] kind=TooLong" 10
  Send-Escape

  # 边界：正好 5000 不该被拒
  Clear-Log
  Set-Clipboard -Value ("b" * 5000)
  Start-Sleep -Milliseconds 400
  Send-Hotkey
  Start-Sleep -Seconds 3
  $falsePositive = Get-Log | Where-Object { $_ -match "kind=TooLong" }
  Send-Escape

  Record "1.7" ($null -ne $hit -and -not $falsePositive) `
    "5001 字符：$(if ($hit) { "判定为 TooLong（$($hit -replace '.*message=','')）" } else { '未命中' })；5000 字符边界未被误拒：$(-not $falsePositive)"
  Stop-Glim $proc
}

# ================================================================ 1.5
# Loading 中按热键 → 旧请求取消，新内容开始，不串台
if (Should-Run "1.5") {
  "=== 1.5：Loading 中按热键 ==="
  $proc = Start-Glim
  Clear-Log

  # 连按三次不同内容。间隔取 250ms —— 实测最快的首字节也要 868ms，
  # 所以第二、三次必然落在上一次的 Loading 期间。
  foreach ($text in @("First sentence about apples.", "Second sentence about oranges.", "Third sentence about bananas.")) {
    Set-Clipboard -Value $text
    Start-Sleep -Milliseconds 250
    Send-Hotkey
    Start-Sleep -Milliseconds 250
  }
  Start-Sleep -Seconds 20
  Send-Escape

  $log = Get-Log
  $starts    = @($log | Where-Object { $_ -match '\[req:start\]' })
  $cancels   = @($log | Where-Object { $_ -match '\[req:cancel\].*reason=superseded' })
  $reloads   = @($log | Where-Object { $_ -match '\[reload\] hotkey-while-loading' })
  $lastDone  = @($log | Where-Object { $_ -match '\[req:done\]' })[-1]

  # 面板不该被关掉：Loading 中按热键是「换内容」不是「toggle 关闭」
  $hidden = @($log | Where-Object { $_ -match '\[hide\] hotkey-toggle' }).Count

  $ok = ($starts.Count -ge 3) -and ($cancels.Count -ge 2) -and ($hidden -eq 0)
  Record "1.5" $ok `
    "发起 $($starts.Count) 次，取消旧请求 $($cancels.Count) 次，Loading 中重载 $($reloads.Count) 次，期间未因 toggle 关闭面板：$($hidden -eq 0)。最后完成的是 $lastDone"
  Stop-Glim $proc
}

# ================================================================ 1.4
# 无 Key → NoApiKey 引导（不是通用报错）
if (Should-Run "1.4") {
  "=== 1.4：未配置 API Key ==="
  # 不动真实凭据：换一个从没存过 Key 的 provider id，
  # 等价于「这个 provider 没配 Key」，跑完还原。
  Edit-Settings { param($s) $s.provider.id = "gate-1-4-no-such-provider" }
  $proc = Start-Glim
  Clear-Log

  Set-Clipboard -Value "Hello world."
  Start-Sleep -Milliseconds 400
  Send-Hotkey
  $hit = Wait-ForLog "\[req:error\] kind=NoApiKey" 15
  Send-Escape
  Stop-Glim $proc
  Restore-Settings

  Record "1.4" ($null -ne $hit) `
    "$(if ($hit) { '判定为 NoApiKey，非通用错误' } else { '未命中 NoApiKey' })。引导卡片的内容需人工核对截图。"
}

# ================================================================ 1.3
# 断网 → Network 错误 + 重试按钮
if (Should-Run "1.3") {
  "=== 1.3：网络不可达 ==="
  # 把端点指向一个不可路由的地址来制造连接失败。
  # 这是「拔网线」的替代手段：两者在 reqwest 侧都落到 is_connect()。
  # 真正拔网线的验证仍建议人工做一次。
  Edit-Settings { param($s) $s.provider.endpoint = "https://127.0.0.1:9/v1beta" }
  $proc = Start-Glim
  Clear-Log

  Set-Clipboard -Value "Hello world."
  Start-Sleep -Milliseconds 400
  Send-Hotkey
  $hit = Wait-ForLog "\[req:error\] kind=Network" 25
  Send-Escape
  Stop-Glim $proc
  Restore-Settings

  Record "1.3" ($null -ne $hit) `
    "$(if ($hit) { "判定为 Network（$($hit -replace '.*message=','')）" } else { '未命中 Network' })。重试按钮需人工点一次确认。"
}

} finally {
  Restore-Settings
  Get-Process -Name Glim -ErrorAction SilentlyContinue | Stop-Process -Force
}

""
"================ 汇总 ================"
$results | Format-Table -AutoSize
""
"settings.json 已还原。以下项目脚本无法覆盖，需人工确认："
"  1.1  译文本身是否正确、是否逐字出现（看截图或亲自按一次热键）"
"  1.3  真正拔掉网线时的表现；错误卡片上的「重试」按钮点了是否重发"
"  1.4  引导卡片是否显示取 Key 的地址与隐私告知，而非普通错误态"
