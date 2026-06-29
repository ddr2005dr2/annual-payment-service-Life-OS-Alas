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

function Get-NslookupText {
  param(
    [string]$HostName,
    [switch]$Txt
  )
  try {
    if ($Txt) {
      return ((nslookup -type=TXT $HostName 2>&1) | Out-String)
    } else {
      return ((nslookup $HostName 2>&1) | Out-String)
    }
  } catch {
    return $_.Exception.Message
  }
}

function Has-RailwayVerifyToken {
  param([string]$Text)
  return ($Text -match 'railway-verify=')
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

$rootHost = $RootDomain
$wwwHost = "www.$RootDomain"
$domainToCheck = if ($UseWww) { $wwwHost } else { $rootHost }

$rootTxtHost = "_railway-verify.$RootDomain"
$wwwTxtHost  = "_railway-verify.www.$RootDomain"

$railwayChecks = @(
  "$RailwayUrl/",
  "$RailwayUrl/#/login",
  "$RailwayUrl/#/signup",
  "$RailwayUrl/#/dashboard",
  "$RailwayUrl/health"
)

$domainChecks = @(
  "https://$domainToCheck/",
  "https://$domainToCheck/#/login",
  "https://$domainToCheck/#/signup",
  "https://$domainToCheck/#/dashboard",
  "https://$domainToCheck/health"
)

Write-Section "RAILWAY BASELINE"
$railwayResults = foreach ($u in $railwayChecks) { Test-Http -Url $u }
$railwayResults | Format-Table -AutoSize

Write-Section "DOMAIN DNS RAW"
$rootDnsText = Get-NslookupText -HostName $rootHost
$wwwDnsText  = Get-NslookupText -HostName $wwwHost
Write-Host $rootDnsText
Write-Host $wwwDnsText

Write-Section "TXT VERIFY RAW"
$rootTxtText = Get-NslookupText -HostName $rootTxtHost -Txt
$wwwTxtText  = Get-NslookupText -HostName $wwwTxtHost -Txt
Write-Host $rootTxtHost
Write-Host $rootTxtText
Write-Host $wwwTxtHost
Write-Host $wwwTxtText

Write-Section "HTTPS CERT TEST"
$tlsRoot = Test-HttpsTls -HostName $rootHost
$tlsWww  = Test-HttpsTls -HostName $wwwHost
@($tlsRoot, $tlsWww) | Format-Table -AutoSize

Write-Section "DOMAIN HTTP CHECKS"
$domainResults = foreach ($u in $domainChecks) { Test-Http -Url $u }
$domainResults | Format-Table -AutoSize

$railwayHealthy = (@($railwayResults | Where-Object { $_.ok }).Count -eq $railwayResults.Count)
$rootTxtPresent = Has-RailwayVerifyToken -Text $rootTxtText
$wwwTxtPresent  = Has-RailwayVerifyToken -Text $wwwTxtText
$rootTlsOk = $tlsRoot.tlsOk
$wwwTlsOk  = $tlsWww.tlsOk

Write-Section "ROOT CAUSE"
if (-not $railwayHealthy) {
  Write-Host "RAILWAY_APP_PROBLEM"
  Write-Host "The Railway deployment itself is not healthy."
}
elseif (-not $rootTxtPresent) {
  Write-Host "ROOT_TXT_MISSING"
  Write-Host "The root domain is missing the Railway TXT verification record."
}
elseif ($UseWww -and -not $wwwTxtPresent) {
  Write-Host "WWW_TXT_MISSING"
  Write-Host "www is configured as a separate hostname but is missing its Railway TXT verification record."
}
elseif (-not $rootTlsOk -and -not $UseWww) {
  Write-Host "ROOT_CERT_NOT_READY"
  Write-Host "Root DNS and TXT are present, but Railway is not yet presenting a trusted certificate for the root hostname."
}
elseif ($UseWww -and -not $wwwTlsOk) {
  Write-Host "WWW_CERT_NOT_READY"
  Write-Host "www DNS/TXT may be present, but Railway is not yet presenting a trusted certificate for www."
}
else {
  Write-Host "DOMAIN_HEALTHY"
  Write-Host "The selected hostname is healthy."
}

Write-Section "FIX PLAN"
if (-not $railwayHealthy) {
  Write-Host "1. Keep using the Railway URL."
  Write-Host "2. Fix the app before touching domain configuration again."
}
elseif (-not $rootTxtPresent) {
  Write-Host "1. In Railway, open the root custom domain entry for $rootHost."
  Write-Host "2. Copy the exact TXT token Railway gives for the root hostname."
  Write-Host "3. Add TXT:"
  Write-Host "   Name: _railway-verify"
  Write-Host "   Value: railway-verify=THE_ROOT_TOKEN_FROM_RAILWAY"
  Write-Host "4. Wait for propagation and re-run this same script."
}
elseif ($UseWww -and -not $wwwTxtPresent) {
  Write-Host "1. In Railway, open the custom domain entry for $wwwHost."
  Write-Host "2. Copy the exact TXT token Railway gives for the www hostname."
  Write-Host "3. Add TXT:"
  Write-Host "   Name: _railway-verify.www"
  Write-Host "   Value: railway-verify=THE_WWW_TOKEN_FROM_RAILWAY"
  Write-Host "4. Wait for propagation and re-run this same script with -UseWww."
}
elseif (-not $UseWww -and $rootTxtPresent -and -not $rootTlsOk) {
  Write-Host "1. Keep ONLY the root domain in Railway for now."
  Write-Host "2. Remove any stuck www domain entry unless you truly need www immediately."
  Write-Host "3. Wait and re-run this script."
  Write-Host "4. If still broken later, remove and re-add ONLY the root custom domain in Railway."
}
elseif ($UseWww -and $wwwTxtPresent -and -not $wwwTlsOk) {
  Write-Host "1. TXT exists, so this is now certificate issuance delay or stuck state."
  Write-Host "2. Wait and re-run this script."
  Write-Host "3. If still broken, remove and re-add ONLY $wwwHost in Railway."
}
else {
  Write-Host "1. No blocking issue detected."
}

Write-Section "RECOMMENDED DECISION"
if ($rootTxtPresent -and -not $rootTlsOk -and -not $wwwTxtPresent) {
  Write-Host "BEST_PATH_NOW = ROOT_ONLY_FIRST"
}
elseif ($UseWww -and -not $wwwTxtPresent) {
  Write-Host "BEST_PATH_NOW = ADD_WWW_TXT_OR_REMOVE_WWW"
}
elseif ($rootTxtPresent -and -not $rootTlsOk) {
  Write-Host "BEST_PATH_NOW = WAIT_OR_READD_ROOT_DOMAIN"
}
else {
  Write-Host "BEST_PATH_NOW = RECHECK_AFTER_PROPAGATION"
}
