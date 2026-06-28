param(
  [Parameter(Mandatory=$true)]
  [string]$BaseUrl = "https://annual-payment-service-life-os-alas-production.up.railway.app",

  [string[]]$SeedPaths = @('/','/login','/signup','/dashboard'),
  [string[]]$ApiPaths = @('/api/health','/api/status','/health','/status'),
  [int]$MaxPages = 25,
  [int]$TimeoutSec = 20,
  [switch]$JsonOut,
  [switch]$SkipLinkChecks,
  [switch]$SkipApiChecks
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Resolve-AbsoluteUrl {
  param([string]$CurrentUrl,[string]$Candidate)
  if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }
  if ($Candidate -match '^(mailto:|tel:|javascript:|#)') { return $null }
  try {
    if ($Candidate -match '^https?://') { return $Candidate }
    return ([uri]::new([uri]$CurrentUrl,$Candidate)).AbsoluteUri
  } catch { return $null }
}

function Get-TitleFromHtml {
  param([string]$Html)
  if ($Html -match '<title[^>]*>(.*?)</title>') { return $matches[1].Trim() }
  return $null
}

function Get-LinksFromHtml {
  param([string]$Html,[string]$CurrentUrl,[string]$BaseHost)
  $matches = [regex]::Matches($Html,'href\s*=\s*["'']([^"'']+)["'']','IgnoreCase')
  $items = New-Object System.Collections.Generic.List[string]
  foreach ($m in $matches) {
    $raw = $m.Groups[1].Value
    $abs = Resolve-AbsoluteUrl -CurrentUrl $CurrentUrl -Candidate $raw
    if ($abs) {
      try {
        $u = [uri]$abs
        if ($u.Host -eq $BaseHost) { $items.Add($u.AbsoluteUri) }
      } catch {}
    }
  }
  return $items | Select-Object -Unique
}

function Find-IntegrityFlags {
  param([string]$Html)
  $flags = New-Object System.Collections.Generic.List[string]
  $patterns = @(
    'Application error',
    'Cannot GET',
    'undefined',
    'TypeError',
    'ReferenceError',
    'Unhandled',
    'Exception',
    'Traceback',
    'SQLITE_',
    'not found',
    'Internal Server Error',
    '502 Bad Gateway',
    '503 Service Unavailable'
  )
  foreach ($p in $patterns) {
    if ($Html -match [regex]::Escape($p)) { $flags.Add($p) }
  }
  if ($Html -match '<form') { $flags.Add('FormDetected') }
  return $flags | Select-Object -Unique
}

function Test-SecurityHeaders {
  param($Headers)
  $required = @(
    'Content-Security-Policy',
    'X-Content-Type-Options',
    'Referrer-Policy'
  )
  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($h in $required) {
    if (-not $Headers[$h]) { $missing.Add($h) }
  }
  return $missing
}

function Invoke-SafeRequest {
  param([string]$Url,[string]$Method='GET')
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $resp = Invoke-WebRequest -Uri $Url -Method $Method -MaximumRedirection 5 -TimeoutSec $TimeoutSec -UseBasicParsing
    $sw.Stop()
    return [pscustomobject]@{
      ok = $true
      statusCode = [int]$resp.StatusCode
      statusDescription = $resp.StatusDescription
      durationMs = [math]::Round($sw.Elapsed.TotalMilliseconds,2)
      headers = $resp.Headers
      finalUrl = $resp.BaseResponse.ResponseUri.AbsoluteUri
      contentType = $resp.Headers['Content-Type']
      contentLength = $resp.RawContentLength
      content = [string]$resp.Content
    }
  } catch {
    $sw.Stop()
    $statusCode = $null
    try { $statusCode = [int]$_.Exception.Response.StatusCode.value__ } catch {}
    return [pscustomobject]@{
      ok = $false
      statusCode = $statusCode
      statusDescription = $_.Exception.Message
      durationMs = [math]::Round($sw.Elapsed.TotalMilliseconds,2)
      headers = @{}
      finalUrl = $Url
      contentType = $null
      contentLength = $null
      content = ''
    }
  }
}

$baseUri = [uri]$BaseUrl
$queue = New-Object System.Collections.Generic.Queue[string]
$visited = New-Object 'System.Collections.Generic.HashSet[string]'
$pageResults = New-Object System.Collections.Generic.List[object]
$linkCheckResults = New-Object System.Collections.Generic.List[object]
$apiResults = New-Object System.Collections.Generic.List[object]

foreach ($p in $SeedPaths) {
  $full = Resolve-AbsoluteUrl -CurrentUrl $BaseUrl -Candidate $p
  if ($full) { $queue.Enqueue($full) }
}
$queue.Enqueue($BaseUrl)

while ($queue.Count -gt 0 -and $visited.Count -lt $MaxPages) {
  $url = $queue.Dequeue()
  if ($visited.Contains($url)) { continue }
  [void]$visited.Add($url)

  $r = Invoke-SafeRequest -Url $url -Method 'GET'
  $html = if ($r.content) { $r.content } else { '' }
  $title = Get-TitleFromHtml -Html $html
  $flags = Find-IntegrityFlags -Html $html
  $missingHeaders = Test-SecurityHeaders -Headers $r.headers
  $links = Get-LinksFromHtml -Html $html -CurrentUrl $url -BaseHost $baseUri.Host

  foreach ($lnk in $links) {
    if (-not $visited.Contains($lnk) -and $visited.Count + $queue.Count -lt $MaxPages) {
      $queue.Enqueue($lnk)
    }
  }

  $pageResults.Add([pscustomobject]@{
    url = $url
    ok = ($r.statusCode -ge 200 -and $r.statusCode -lt 400)
    statusCode = $r.statusCode
    statusDescription = $r.statusDescription
    durationMs = $r.durationMs
    title = $title
    finalUrl = $r.finalUrl
    contentType = $r.contentType
    contentLength = $r.contentLength
    discoveredLinks = $links.Count
    missingSecurityHeaders = @($missingHeaders)
    integrityFlags = @($flags)
  })

  if (-not $SkipLinkChecks) {
    $sample = $links | Select-Object -First 8
    foreach ($l in $sample) {
      $lr = Invoke-SafeRequest -Url $l -Method 'HEAD'
      $linkCheckResults.Add([pscustomobject]@{
        sourceUrl = $url
        targetUrl = $l
        ok = ($lr.statusCode -ge 200 -and $lr.statusCode -lt 400)
        statusCode = $lr.statusCode
        durationMs = $lr.durationMs
      })
    }
  }
}

if (-not $SkipApiChecks) {
  foreach ($ap in $ApiPaths) {
    $fullApi = Resolve-AbsoluteUrl -CurrentUrl $BaseUrl -Candidate $ap
    if (-not $fullApi) { continue }
    $ar = Invoke-SafeRequest -Url $fullApi -Method 'GET'
    $snippet = $null
    if ($ar.content) {
      $snippet = ($ar.content -replace '\s+',' ')
      if ($snippet.Length -gt 220) { $snippet = $snippet.Substring(0,220) }
    }
    $apiResults.Add([pscustomobject]@{
      url = $fullApi
      ok = ($ar.statusCode -ge 200 -and $ar.statusCode -lt 400)
      statusCode = $ar.statusCode
      durationMs = $ar.durationMs
      contentType = $ar.contentType
      contentSnippet = $snippet
    })
  }
}

$failedPages = @($pageResults | Where-Object { -not $_.ok }).Count
$flaggedPages = @($pageResults | Where-Object { $_.integrityFlags.Count -gt 0 -or $_.missingSecurityHeaders.Count -gt 0 }).Count
$brokenLinks = @($linkCheckResults | Where-Object { -not $_.ok }).Count
$healthyApis = @($apiResults | Where-Object { $_.ok }).Count

$summary = [pscustomobject]@{
  scannedAt = (Get-Date).ToString('s')
  baseUrl = $BaseUrl
  totalPagesScanned = $pageResults.Count
  failedPages = $failedPages
  flaggedPages = $flaggedPages
  totalLinkChecks = $linkCheckResults.Count
  brokenLinks = $brokenLinks
  totalApiChecks = $apiResults.Count
  healthyApis = $healthyApis
  overallPass = (($failedPages -eq 0) -and ($brokenLinks -eq 0))
}

$report = [pscustomobject]@{
  summary = $summary
  pages = $pageResults
  links = $linkCheckResults
  apis = $apiResults
}

if ($JsonOut) {
  $report | ConvertTo-Json -Depth 8
  exit
}

"=== CAT Launch Ops Summary ==="
$summary.PSObject.Properties | ForEach-Object { "{0}: {1}" -f $_.Name, $_.Value }
""
"=== Pages ==="
$pageResults | Sort-Object url | Format-Table url,ok,statusCode,title,durationMs,discoveredLinks -AutoSize
""
if ($linkCheckResults.Count -gt 0) {
  "=== Broken / Flagged Links ==="
  $badLinks = $linkCheckResults | Where-Object { -not $_.ok }
  if ($badLinks.Count -gt 0) {
    $badLinks | Format-Table sourceUrl,targetUrl,statusCode,durationMs -AutoSize
  } else {
    "No broken sampled links detected."
  }
  ""
}
if ($apiResults.Count -gt 0) {
  "=== API Probes ==="
  $apiResults | Format-Table url,ok,statusCode,durationMs,contentType -AutoSize
  ""
}
"=== Page Flags ==="
foreach ($p in $pageResults) {
  "--- $($p.url) ---"
  if ($p.missingSecurityHeaders.Count -gt 0) { "Missing security headers: $($p.missingSecurityHeaders -join ', ')" }
  if ($p.integrityFlags.Count -gt 0) { "Integrity flags: $($p.integrityFlags -join ', ')" }
  if ($p.missingSecurityHeaders.Count -eq 0 -and $p.integrityFlags.Count -eq 0) { "No major flags detected." }
  ""
}
