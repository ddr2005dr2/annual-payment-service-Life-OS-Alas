param(
  [string]$BaseUrl = "https://annual-payment-service-life-os-alas-production.up.railway.app",
  [int]$TimeoutSec = 20
)

$ErrorActionPreference = 'Stop'
$paths = @('/','/#/login','/#/signup','/#/dashboard','/health')
$results = @()

foreach ($p in $paths) {
  $url = $BaseUrl.TrimEnd('/') + $p
  try {
    $r = Invoke-WebRequest -Uri $url -MaximumRedirection 5 -TimeoutSec $TimeoutSec -UseBasicParsing
    $title = ''
    if ($r.Content -match '<title>(.*?)</title>') { $title = $matches[1] }
    $results += [pscustomobject]@{
      url = $url
      ok = ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
      statusCode = [int]$r.StatusCode
      title = $title
    }
  } catch {
    $statusCode = $null
    try { $statusCode = [int]$_.Exception.Response.StatusCode.value__ } catch {}
    $results += [pscustomobject]@{
      url = $url
      ok = $false
      statusCode = $statusCode
      title = ''
    }
  }
}

$results | Format-Table -AutoSize
