param(
  [string]$RootDomain = "lifeosatlas.com",
  [string]$RailwayUrl = "https://annual-payment-service-life-os-alas-production.up.railway.app",
  [int]$TimeoutSec = 20
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Section {
  param([string]$Name)
  Write-Host ""
  Write-Host ("=" * 12 + " " + $Name + " " + "=" * 12)
}

function Test-Http {
  param([string]$Url)
  try {
    $r = Invoke-WebRequest -Uri $Url -MaximumRedirection 5 -TimeoutSec $TimeoutSec -UseBasicParsing
    $title = ""
    if ($r.Content -match "<title>(.*?)</title>") { $title = $matches[1] }
    [pscustomobject]@{
      url        = $Url
      ok         = ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
      statusCode = [int]$r.StatusCode
      title      = $title
      error      = ""
    }
  } catch {
    $code = 0
    try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode.value__ } } catch {}
    [pscustomobject]@{
      url        = $Url
      ok         = $false
      statusCode = $code
      title      = ""
      error      = $_.Exception.Message
    }
  }
}

function Test-HttpsTls {
  param([string]$HostName)
  try {
    $req = [System.Net.HttpWebRequest]::Create("https://$HostName/")
    $req.Method = "GET"
    $req.Timeout = $TimeoutSec * 1000
    $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse()
    $resp.Close()
    [pscustomobject]@{
      host  = $HostName
      tlsOk = $true
      error = ""
    }
  } catch {
    [pscustomobject]@{
      host  = $HostName
      tlsOk = $false
      error = $_.Exception.Message
    }
  }
}

Write-Section "RAILWAY BASELINE"
$railwayChecks = @(
  "$RailwayUrl/",
  "$RailwayUrl/#/login",
  "$RailwayUrl/#/signup",
  "$RailwayUrl/#/dashboard",
  "$RailwayUrl/health"
)
$railwayResults = foreach ($u in $railwayChecks) { Test-Http -Url $u }
$railwayResults | Format-Table -AutoSize
$railwayHealthy = (@($railwayResults | Where-Object { $_.ok }).Count -eq $railwayResults.Count)

Write-Section "DNS NAMESERVERS (NS)"
$nsHosts = @()
try {
  $ns = Resolve-DnsName -Name $RootDomain -Type NS -DnsOnly -ErrorAction Stop
  $nsHosts = $ns | Where-Object { $_.Type -eq "NS" } | Select-Object -ExpandProperty NameHost
} catch {
  $nsHosts = @()
}
if (-not $nsHosts -or $nsHosts.Count -eq 0) {
  Write-Host "NS_HOSTS=NONE"
} else {
  Write-Host ("NS_HOSTS=" + ($nsHosts -join ", "))
}

Write-Section "HTTPS CERT TEST"
$tlsRoot = Test-HttpsTls -HostName $RootDomain
$tlsWww  = Test-HttpsTls -HostName ("www.$RootDomain")
@($tlsRoot, $tlsWww) | Format-Table -AutoSize

Write-Section "RAILWAY DNS INSTRUCTIONS"
Write-Host "1. In Railway, open the custom domain entry for $RootDomain."
Write-Host "2. Railway will show a TXT record and a routing record (usually CNAME or ALIAS) that must be created at your DNS."
Write-Host "3. TXT format:"
Write-Host "   Type : TXT"
Write-Host "   Name : _railway-verify"
Write-Host "   Value: railway-verify=<RAILWAY_VERIFICATION_TOKEN_FOR_ROOT>"
Write-Host "4. Routing record depends on Railway's instructions for apex domains."
Write-Host "5. After DNS is updated, rerun this script to validate TLS."

Write-Section "STATE SUMMARY"
Write-Host ("RAILWAY_HEALTHY=" + $railwayHealthy)
Write-Host ("ROOT_TLS_OK=" + $tlsRoot.tlsOk)
Write-Host ("WWW_TLS_OK=" + $tlsWww.tlsOk)
