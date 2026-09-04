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
  [switch]$NoThinking,
  [string]$Models,
  [int]$Runs = 10,
  [string]$Proxy = $env:HTTPS_PROXY
)

$ErrorActionPreference = "Stop"
$settingsPath = Join-Path $env:APPDATA "glim\settings.json"

# 截断到 n 个字符。直接 Substring(0, n) 在响应短于 n 时会抛异常 ——
# 上一版就是这么崩的，而且恰好崩在唯一能看到服务端原话的地方。
function Limit-Text {
  param([string]$Text, [int]$Max = 300)
  if (-not $Text) { return "(空响应)" }
  $t = ($Text -replace '\s+', ' ').Trim()
  if ($t.Length -le $Max) { return $t }
  return $t.Substring(0, $Max) + "…"
}

function Get-KeyFromClipboard {
  $k = ((Get-Clipboard) -join "").Trim()
  if (-not $k) { throw "剪贴板里没有内容。先复制 API Key，或用 -Key 参数传进来。" }
  # 必须用 Write-Host：PowerShell 的函数会把所有未捕获的输出并入返回值，
  # 裸写字符串会让调用方拿到「提示语 + Key」的数组，插进请求头就成了
  # 一串带中文的垃圾，服务端一律回 API_KEY_INVALID。
  Write-Host "（Key 取自剪贴板，前 6 位 $($k.Substring(0, [Math]::Min(6, $k.Length)))…）"
  return $k
}

# ---------------------------------------------------------------- -Bench 模式
# 用 curl 直接打流式端点，绕开 Glim 的全部代码。time_starttransfer 即首字节
# 延迟 —— 门禁 1.2 要求 p50 < 1200ms。
#
#   -Models a,b,c   横向对比多个模型（不给就用配置里的那个）
#   -NoThinking     额外跑一组带 thinkingConfig 的请求做对比
if ($Bench) {
  if (-not $Key) { $Key = Get-KeyFromClipboard }

  $configured = "gemini-flash-lite-latest"
  if (Test-Path $settingsPath) {
    $cfg = Get-Content $settingsPath -Raw | ConvertFrom-Json
    if ($cfg.provider.model) { $configured = $cfg.provider.model }
  }
  $modelList = if ($Models) { $Models -split '\s*,\s*' } else { @($configured) }

  "对比模型：$($modelList -join ', ')"
  if ($Proxy) { "代理：$Proxy" }
  ""

  $prompt = "Translate into Chinese, output only the translation: The quick brown fox jumps over the lazy dog."

  # 手写 JSON 字面量。ConvertTo-Json 会把单元素数组拆成对象，contents 结构就错了。
$bodyDefault = @"
{"contents":[{"role":"user","parts":[{"text":"$prompt"}]}]}
"@
$bodyNoThinking = @"
{"contents":[{"role":"user","parts":[{"text":"$prompt"}]}],"generationConfig":{"thinkingConfig":{"thinkingBudget":0}}}
"@

  $bodies = @( @{ Name = "默认"; Json = $bodyDefault } )
  if ($NoThinking) { $bodies += @{ Name = "关掉思考"; Json = $bodyNoThinking } }

  $summary = @()

  foreach ($model in $modelList) {
    foreach ($body in $bodies) {
      $label = if ($bodies.Count -gt 1) { "$model / $($body.Name)" } else { $model }
      "【$label】"

      $file = Join-Path $env:TEMP "glim-bench.json"
      Set-Content -LiteralPath $file -Value $body.Json -Encoding UTF8 -NoNewline
      $url = "https://generativelanguage.googleapis.com/v1beta/models/${model}:streamGenerateContent?alt=sse"

      $samples = @()
      $failures = 0
      $aborted = $false
      for ($i = 1; $i -le $Runs; $i++) {
        $curlArgs = @(
          "-sS", "-o", "NUL",
          "-H", "x-goog-api-key: $Key",
          "-H", "Content-Type: application/json",
          "--data-binary", "@$file",
          "-w", "%{http_code} %{time_starttransfer}"
        )
        if ($Proxy) { $curlArgs += @("--proxy", $Proxy) }
        $curlArgs += $url

        $out = (& curl.exe @curlArgs) -split '\s+'
        if ($out.Count -lt 2) { "  第 $i 次：curl 无输出"; continue }

        $code = $out[0]
        $ttfb = [double]$out[1] * 1000
        "  第 $i 次：HTTP $code  首字节 $([math]::Round($ttfb)) ms"

        if ($code -eq "200") {
          $samples += $ttfb
        } else {
          # 非 200 就把服务端原话打出来 —— 只报状态码等于没报。
          $detailArgs = @("-sS", "-H", "x-goog-api-key: $Key", "-H", "Content-Type: application/json", "--data-binary", "@$file")
          if ($Proxy) { $detailArgs += @("--proxy", $Proxy) }
          $detailArgs += $url
          "    服务端返回：" + (Limit-Text ((& curl.exe @detailArgs) -join " "))

          # 只有结构性拒绝才值得中止：请求体或模型不被接受，重试多少次都一样。
          # 429 / 5xx 是临时故障 —— 上一版把 503 也当成结构性拒绝，于是
          # gemini-3.5-flash-lite 只采到 1 个样本就收工，还被汇总表判成「达标」。
          # 临时故障要计入失败率继续跑，不能提前收摊。
          if ($code -in @("400", "401", "403", "404")) {
            $aborted = $true
            break
          }
          $failures += 1
        }
        Start-Sleep -Seconds 5   # 免费层约 15 RPM，别把自己限流了
      }

      Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue

      if ($samples.Count -gt 0) {
        $sorted = $samples | Sort-Object
        $p50 = $sorted[[int]($sorted.Count / 2)]
        "  → 最小 $([math]::Round($sorted[0])) ms  中位 $([math]::Round($p50)) ms  最大 $([math]::Round($sorted[-1])) ms  成功 $($samples.Count)/$Runs"
        $summary += [pscustomobject]@{
          配置 = $label
          样本 = "$($samples.Count)/$Runs"
          最小 = [math]::Round($sorted[0])
          中位 = [math]::Round($p50)
          最大 = [math]::Round($sorted[-1])
        }
      } elseif ($aborted) {
        "  → 请求体或模型不被接受，已跳过剩余次数"
      } else {
        "  → 没有成功的样本"
      }
      ""
    }
  }

  if ($summary.Count -gt 0) {
    "汇总（门禁 1.2 要求首字符 p50 < 1200ms，取 10 次的中位数）："
    $summary |
      Select-Object 配置, 样本, 最小, 中位, 最大, @{n='1.2'; e={
        # 样本不足 10 个就不给结论。门禁写的是「记录 10 次，取中位数」，
        # 拿 1 个样本判「达标」是自欺 —— 上一版就这么干过。
        $n = [int](($_.样本 -split '/')[0])
        if ($n -lt 10) { "样本不足($n)" }
        elseif ($_.中位 -lt 1200) { '达标' }
        else { '不达标' }
      }} |
      Format-Table -AutoSize
    ""
    "注意：实测同一配置在不同时段的中位数可相差十倍（1417ms vs 13930ms），"
    "单次 bench 不足以判定门禁，需在不同时段重复取样。"
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
