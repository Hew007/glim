<#
  列出当前 API Key 可用的模型，并可直接写进配置。

  用法:
    pwsh -File tools/models.ps1                 # 列出可用模型（Key 从剪贴板读）
    pwsh -File tools/models.ps1 -Key "AIza..."  # 显式给 Key
    pwsh -File tools/models.ps1 -Set gemini-x   # 把配置里的模型改成 gemini-x

  §4.3 规定模型串写在配置里、不硬编码 —— 模型改名频繁，这个脚本就是
  用来跟上改名的，不需要改代码、不需要重新构建。
#>
param(
  [string]$Key,
  [string]$Set,
  [switch]$Bench,
  [int]$Runs = 5,
  [string]$Proxy = $env:HTTPS_PROXY
)

$ErrorActionPreference = "Stop"
$settingsPath = Join-Path $env:APPDATA "glim\settings.json"

function Get-KeyFromClipboard {
  $k = ((Get-Clipboard) -join "").Trim()
  if (-not $k) { throw "剪贴板里没有内容。先复制 API Key，或用 -Key 参数传进来。" }
  "（Key 取自剪贴板，前 6 位 $($k.Substring(0, [Math]::Min(6, $k.Length)))…）"
  return $k
}

# ---------------------------------------------------------------- -Bench 模式
# 直接拿 curl 打同一个流式端点，绕开 Glim 自己的代码。
# time_starttransfer 就是首字节延迟 —— 门禁 1.2 要求 p50 < 1200ms。
# 这里量的是链路 + 模型；如果这里就慢，那跟 Rust 侧无关。
if ($Bench) {
  if (-not $Key) { $Key = Get-KeyFromClipboard }

  $model = "gemini-flash-lite-latest"
  if (Test-Path $settingsPath) {
    $cfg = Get-Content $settingsPath -Raw | ConvertFrom-Json
    if ($cfg.provider.model) { $model = $cfg.provider.model }
  }
  "模型：$model"
  if ($Proxy) { "代理：$Proxy" }

  $url = "https://generativelanguage.googleapis.com/v1beta/models/${model}:streamGenerateContent?alt=sse"
  $body = @{
    contents = @(@{ role = "user"; parts = @(@{ text = "Translate to Chinese: The quick brown fox jumps over the lazy dog." }) })
  } | ConvertTo-Json -Depth 10 -Compress

  $bodyFile = Join-Path $env:TEMP "glim-bench.json"
  Set-Content -LiteralPath $bodyFile -Value $body -Encoding UTF8

  $samples = @()
  for ($i = 1; $i -le $Runs; $i++) {
    $args = @(
      "-sS", "-o", "NUL",
      "-H", "x-goog-api-key: $Key",
      "-H", "Content-Type: application/json",
      "--data-binary", "@$bodyFile",
      "-w", "%{http_code} %{time_namelookup} %{time_connect} %{time_starttransfer} %{time_total}"
    )
    if ($Proxy) { $args += @("--proxy", $Proxy) }
    $args += $url

    $out = (& curl.exe @args) -split '\s+'
    if ($out.Count -lt 5) { "  第 $i 次：curl 无输出"; continue }

    $code = $out[0]
    $ttfb = [double]$out[3] * 1000
    $total = [double]$out[4] * 1000
    "  第 $i 次：HTTP $code  首字节 $([math]::Round($ttfb)) ms  总计 $([math]::Round($total)) ms"
    if ($code -eq "200") { $samples += $ttfb }
    Start-Sleep -Seconds 5   # 免费层约 15 RPM，别把自己限流了
  }

  Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue

  if ($samples.Count -gt 0) {
    $sorted = $samples | Sort-Object
    $p50 = $sorted[[int]($sorted.Count / 2)]
    ""
    "首字节延迟：最小 $([math]::Round($sorted[0])) ms  中位 $([math]::Round($p50)) ms  最大 $([math]::Round($sorted[-1])) ms"
    "门禁 1.2 要求 p50 < 1200ms —— $(if ($p50 -lt 1200) { '达标' } else { '不达标' })"
  } else {
    "没有成功的样本。"
  }
  return
}

# ---------------------------------------------------------------- -Set 模式
if ($Set) {
  if (-not (Test-Path $settingsPath)) {
    # 文件不存在是常态而不是异常：Glim 只在保存设置时才写盘，
    # 没改过热键的话它一直不存在。直接建一个完整的默认配置。
    "配置文件不存在，新建：$settingsPath"
    New-Item -ItemType Directory -Force -Path (Split-Path $settingsPath) | Out-Null
    @{
      hotkey    = "Ctrl+Alt+D"
      languages = @{ native = "zh"; foreign = "en" }
      provider  = @{
        id          = "gemini"
        model       = $Set
        endpoint    = "https://generativelanguage.googleapis.com/v1beta"
        api_key_url = "https://aistudio.google.com/apikey"
      }
    } | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
    "已把模型设为：$Set"
    "重启 Glim 生效： Get-Process Glim -EA SilentlyContinue | Stop-Process -Force"
    return
  }
  $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
  if (-not $settings.provider) {
    # M0 时期落盘的配置只有 hotkey，provider 整块是缺的。
    $settings | Add-Member -NotePropertyName provider -NotePropertyValue ([pscustomobject]@{
      id           = "gemini"
      model        = $Set
      endpoint     = "https://generativelanguage.googleapis.com/v1beta"
      api_key_url  = "https://aistudio.google.com/apikey"
    }) -Force
  } else {
    $settings.provider.model = $Set
  }
  $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8
  "已把模型改为：$Set"
  "配置文件：$settingsPath"
  "重启 Glim 生效： Get-Process Glim -EA SilentlyContinue | Stop-Process -Force"
  return
}

# ---------------------------------------------------------------- 列出模型
if (-not $Key) { $Key = Get-KeyFromClipboard }

$endpoint = "https://generativelanguage.googleapis.com/v1beta/models"
$params = @{
  Uri     = $endpoint
  Headers = @{ "x-goog-api-key" = $Key }
  Method  = "GET"
}
if ($Proxy) {
  $params.Proxy = $Proxy
  "（走代理 $Proxy）"
}

try {
  $response = Invoke-RestMethod @params
} catch {
  "请求失败：$($_.Exception.Message)"
  if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message }
  return
}

# 早期版本只按 supportedGenerationMethods 筛，实测该字段在响应里已经不存在，
# 于是筛出 0 个、误报成「没有支持流式的模型」。字段在就用字段，不在就退回
# 按名字排除明显不是文本生成的那些族（图像、视频、音乐、语音、向量…）。
$hasMethods = @($response.models | Where-Object { $_.supportedGenerationMethods }).Count -gt 0

$nonText = 'embedding|^models/veo|lyria|-tts|image|transcribe|audio|^models/aqa|robotics|computer-use|deep-research|nano-banana|antigravity'

if ($hasMethods) {
  $streaming = @($response.models | Where-Object {
    $_.supportedGenerationMethods -contains 'streamGenerateContent'
  })
  "（按 supportedGenerationMethods 字段筛选）"
} else {
  $streaming = @($response.models | Where-Object { $_.name -notmatch $nonText })
  "（响应里没有 supportedGenerationMethods 字段，改为按模型族排除非文本模型 ——"
  " 这是推断，最终以实际能否翻译为准）"
}

if ($streaming.Count -eq 0) {
  "筛不出可用的文本模型。返回的全部模型："
  $response.models | Select-Object @{n='模型串';e={$_.name -replace '^models/',''}} | Format-Table -AutoSize
  return
}

"候选模型（$($streaming.Count) 个）："
$streaming |
  Select-Object `
    @{n='模型串'; e={ $_.name -replace '^models/','' }},
    @{n='名称';   e={ $_.displayName }},
    @{n='输入上限'; e={ $_.inputTokenLimit }} |
  Format-Table -AutoSize

# 优先挑 `-latest` 别名：Google 改模型名时别名自动跟着走，不会再出现
# 写死的型号某天突然 404 的情况。
$pick =
  ($streaming | Where-Object { $_.name -match 'flash-lite-latest' } | Select-Object -First 1) ??
  ($streaming | Where-Object { $_.name -match 'flash-latest' }      | Select-Object -First 1) ??
  ($streaming | Where-Object { $_.name -match 'lite' }              | Select-Object -First 1) ??
  ($streaming | Where-Object { $_.name -match 'flash' }             | Select-Object -First 1)
if ($pick) {
  $name = $pick.name -replace '^models/',''
  ""
  "建议用这个（最轻量，首字符最快）：$name"
  "直接设上：  pwsh -File tools/models.ps1 -Set $name"
}
