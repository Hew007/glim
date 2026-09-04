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
  [string]$Proxy = $env:HTTPS_PROXY
)

$ErrorActionPreference = "Stop"
$settingsPath = Join-Path $env:APPDATA "glim\settings.json"

# ---------------------------------------------------------------- -Set 模式
if ($Set) {
  if (-not (Test-Path $settingsPath)) {
    throw "找不到配置文件 $settingsPath —— 先启动一次 Glim 让它生成。"
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
if (-not $Key) {
  $Key = (Get-Clipboard) -join ""
  $Key = $Key.Trim()
  if (-not $Key) { throw "剪贴板里没有内容。先复制 API Key，或用 -Key 参数传进来。" }
  "（Key 取自剪贴板，前 6 位 $($Key.Substring(0, [Math]::Min(6, $Key.Length)))…）"
}

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
