param(
  [string]$RailwayUrl = "https://annual-payment-service-life-os-alas-production.up.railway.app",
  [string]$DomainUrl  = "https://lifeosatlas.com",
  [int]$TimeoutSec    = 20
)

$ErrorActionPreference = 'Stop'

function Test-Urls {
  param(
    [string]$Base,
    [string]$Label
  )

  $paths = @('/','/#/login','/#/signup','/#/dashboard','/health')
  $results = @()

  foreach ($p in $paths) {
    $url = $Base.TrimEnd('/') + $p
    try {
      $r = Invoke-WebRequest -Uri $url -MaximumRedirection 5 -TimeoutSec $TimeoutSec -UseBasicParsing
      $title = ''
      if ($r.Content -match '<title>(.*?)</title>') { $title = $matches[1] }
      $results += [pscustomobject]@{
        target    = $Label
        url       = $url
        ok        = ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
        status    = [int]$r.StatusCode
        title     = $title
      }
    } catch {
      $code = $null
      try { $code = [int]$_.Exception.Response.StatusCode.value__ } catch {}
      $results += [pscustomobject]@{
        target    = $Label
        url       = $url
        ok        = $false
        status    = $code
        title     = ''
      }
    }
  }

  $results
}

$railwayResults = Test-Urls -Base $RailwayUrl -Label 'railway'
$domainResults  = Test-Urls -Base $DomainUrl  -Label 'domain'

$railwayResults + $domainResults | Format-Table -AutoSize
