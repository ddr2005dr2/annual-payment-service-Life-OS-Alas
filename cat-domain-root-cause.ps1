param(
  [string]$RootDomain = "lifeosatlas.com",
  [string]$RailwayUrl = "https://annual-payment-service-life-os-alas-production.up.railway.app",
  [switch]$UseWww,
  [int]$TimeoutSec = 20
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Section {
  param([string]$Name)
  Write-Host ""
  Write-Host ("=" * 12 + " " + $Name + " " + "=" * 12)
}

function Resolve-Txt {
  param([string]$HostName)
  try {
    $out = nslookup -type=TXT $HostName 2>&1 | Out-String
    return $out.Trim()
  } catch {
    return $_.Exception.Message
  }
}

function Resolve-Dns {
  param([string]$HostName)
  try {
    $out = nslookup $HostName 2>&1 | Out-String
    return $out.Trim()
  } catch {
    return $_.Exception.Message
  }
}

function Test-Http {
  param([string]$Url)
  try {
    $r = Invoke-WebRequest -Uri $Url -MaximumRedirection 5 -TimeoutSec $TimeoutSec -UseBasicParsing
    $title = ""
    if ($r.Content -match "<title>(.*?)</title>") { $title = $matches[1] }
    return [pscustomobject]@{
      url        = $Url
      ok         = ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
      statusCode = [int]$r.StatusCode
      title      = $title
      error      = ""
    }
  } catch {
    $code = $null
    try { $code = [int]$_.Exception.Response.StatusCode.value__ } catch {}
    return [pscustomobject]@{
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
    return [pscustomobject]@{
      host   = $HostName
      tlsOk  = $true
      error  = ""
    }
  } catch {
    return [pscustomobject]@{
      host   = $HostName
      tlsOk  = $false
      error  = $_.Exception.Message
    }
  }
}

$DomainToCheck = if ($UseWww) { "www.$RootDomain" } else { $RootDomain }
$RootTxtHost = "_railway-verify.$RootDomain"
$WwwTxtHost  = "_railway-verify.www.$RootDomain"

$RailwayChecks = @(
  "$RailwayUrl/",
  "$RailwayUrl/#/login",
  "$RailwayUrl/#/signup",
  "$RailwayUrl/#/dashboard",
  "$RailwayUrl/health"
)

$DomainChecks = @(
  "https://$DomainToCheck/",
  "https://$DomainToCheck/#/login",
  "https://$DomainToCheck/#/signup",
  "https://$DomainToCheck/#/dashboard",
  "https://$DomainToCheck/health"
)

Write-Section "RAILWAY BASELINE"
$railwayResults = foreach ($u in $RailwayChecks) { Test-Http -Url $u }
$railwayResults | Format-Table -AutoSize

Write-Section "DOMAIN DNS"
Resolve-Dns $RootDomain
Write-Host ""
Resolve-Dns ("www." + $RootDomain)

Write-Section "TXT VERIFY"
Write-Host $RootTxtHost
Resolve-Txt $RootTxtHost
Write-Host ""
Write-Host $WwwTxtHost
Resolve-Txt $WwwTxtHost

Write-Section "HTTPS CERT TEST"
$tlsRoot = Test-HttpsTls -HostName $RootDomain
$tlsWww  = Test-HttpsTls -HostName ("www." + $RootDomain)
@($tlsRoot, $tlsWww) | Format-Table -AutoSize

Write-Section "DOMAIN HTTP CHECKS"
$domainResults = foreach ($u in $DomainChecks) { Test-Http -Url $u }
$domainResults | Format-Table -AutoSize

$railwayHealthy = (@($railwayResults | Where-Object { $_.ok }).Count -eq $railwayResults.Count)
$rootTxtPresent = ((Resolve-Txt $RootTxtHost) -match "railway-verify=")
$wwwTxtPresent  = ((Resolve-Txt $WwwTxtHost) -match "railway-verify=")
$rootTlsOk      = $tlsRoot.tlsOk
$wwwTlsOk       = $tlsWww.tlsOk

Write-Section "ROOT CAUSE"
if (-not $railwayHealthy) {
  Write-Host "RAILWAY_APP_PROBLEM"
  Write-Host "The Railway deployment itself is not healthy. Stop domain work and fix the app first."
}
elseif ($UseWww -and -not $wwwTxtPresent) {
  Write-Host "WWW_TXT_MISSING"
  Write-Host "www is being treated as a separate hostname and is missing its Railway TXT verification record."
}
elseif (-not $rootTxtPresent) {
  Write-Host "ROOT_TXT_MISSING"
  Write-Host "The root domain is missing the Railway TXT verification record."
}
elseif (-not $rootTlsOk -and -not $UseWww) {
  Write-Host "ROOT_CERT_NOT_READY"
  Write-Host "The root domain points to Railway and TXT exists, but Railway is not yet presenting a trusted certificate."
}
elseif ($UseWww -and -not $wwwTlsOk) {
  Write-Host "WWW_CERT_NOT_READY"
  Write-Host "www points to Railway but Railway is not yet presenting a trusted certificate for www."
}
else {
  Write-Host "DOMAIN_HEALTHY"
  Write-Host "The selected domain path is healthy."
}

Write-Section "FIX PLAN"
if (-not $railwayHealthy) {
  Write-Host "1. Keep using the Railway URL until all Railway checks return 200."
  Write-Host "2. Do not change DNS again until the app itself is healthy."
}
elseif ($UseWww -and -not $wwwTxtPresent) {
  Write-Host "1. In Railway, open the custom domain entry for www.$RootDomain and copy its exact verification token."
  Write-Host "2. Add TXT at your DNS provider:"
  Write-Host "   Name: _railway-verify.www"
  Write-Host "   Value: railway-verify=THE_TOKEN_FROM_RAILWAY"
  Write-Host "3. Wait for propagation."
  Write-Host "4. Re-run this same script with -UseWww."
}
elseif (-not $UseWww -and $rootTxtPresent -and -not $rootTlsOk) {
  Write-Host "1. Keep ONLY the root domain in Railway for now."
  Write-Host "2. Remove any stuck www domain entry in Railway unless you explicitly need www right now."
  Write-Host "3. Wait and re-run this same script."
  Write-Host "4. If TLS is still not trusted after waiting, remove and re-add ONLY the root custom domain in Railway."
}
elseif ($UseWww -and $wwwTxtPresent -and -not $wwwTlsOk) {
  Write-Host "1. TXT exists, so this is likely certificate issuance delay/stuck state."
  Write-Host "2. Wait and re-run this same script."
  Write-Host "3. If still broken, remove and re-add ONLY www.$RootDomain in Railway."
}
elseif ($rootTlsOk -and -not $UseWww) {
  Write-Host "1. Root domain is ready."
  Write-Host "2. If you want www too, add it separately in Railway and create _railway-verify.www with the exact token Railway gives."
}
else {
  Write-Host "1. No blocking issue detected for the selected hostname."
}

Write-Section "RECOMMENDED DECISION"
if ($rootTxtPresent -and -not $rootTlsOk -and -not $wwwTxtPresent) {
  Write-Host "BEST_PATH_NOW = ROOT_ONLY_FIRST"
  Write-Host "Do not pursue www until the root domain is serving a trusted certificate."
}
elseif ($UseWww -and -not $wwwTxtPresent) {
  Write-Host "BEST_PATH_NOW = ADD_WWW_TXT_OR_REMOVE_WWW"
}
else {
  Write-Host "BEST_PATH_NOW = RECHECK_AFTER_PROPAGATION"
}
