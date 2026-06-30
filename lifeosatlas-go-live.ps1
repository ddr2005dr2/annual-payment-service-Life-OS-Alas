param(
  [string]$CloudflareApiToken,
  [string]$Domain = "lifeosatlas.com",
  [string]$WwwDomain = "www.lifeosatlas.com",
  [string]$RailwayTarget = "smlqeiav.up.railway.app",
  [string]$RailwayVerifyTxtName = "_railway-verify.www.lifeosatlas.com",
  [string]$RailwayVerifyTxtValue = "railway-verify=f70647c5653a0516bd8aeeabef7bc99aa70496c8cb4b37c5324ad46024f606be",
  [string]$ApexRedirectIPv4 = "192.0.2.1",
  [switch]$ApplyDns,
  [switch]$ApplyRedirect
)

$ErrorActionPreference = 'Stop'

function Get-Token {
  param([string]$Token)
  if ($Token) { return $Token }
  $secure = Read-Host "Paste Cloudflare API token" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
}

$CloudflareApiToken = Get-Token -Token $CloudflareApiToken

$Headers = @{
  Authorization = "Bearer $CloudflareApiToken"
  'Content-Type' = 'application/json'
}

function Invoke-CF {
  param(
    [ValidateSet('GET','POST','PUT','DELETE')]
    [string]$Method,
    [string]$Uri,
    $Body = $null
  )

  try {
    if ($null -ne $Body) {
      return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body ($Body | ConvertTo-Json -Depth 30)
    }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
  }
  catch {
    if ($_.Exception.Response) {
      $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      $responseBody = $reader.ReadToEnd()
      Write-Host "Cloudflare API error response:" -ForegroundColor Red
      Write-Host $responseBody -ForegroundColor Red
    }
    throw
  }
}

Write-Host "Looking up Zone ID for $Domain..." -ForegroundColor Cyan
$zoneLookup = Invoke-CF -Method GET -Uri ("https://api.cloudflare.com/client/v4/zones?name=" + $Domain + "&status=active")
if (-not $zoneLookup.success -or -not $zoneLookup.result -or $zoneLookup.result.Count -lt 1) {
  throw "Could not find Zone ID for $Domain. Check that the zone exists and this token has access."
}
$CloudflareZoneId = $zoneLookup.result[0].id
Write-Host "Found Zone ID: $CloudflareZoneId" -ForegroundColor Green

function Get-DnsRecords {
  (Invoke-CF -Method GET -Uri ("https://api.cloudflare.com/client/v4/zones/" + $CloudflareZoneId + "/dns_records?per_page=100")).result
}

function Remove-Records {
  param($Records, [string]$Reason)
  foreach ($rec in $Records) {
    Write-Host ("Deleting " + $rec.type + " " + $rec.name + " (" + $Reason + ")") -ForegroundColor Yellow
    Invoke-CF -Method DELETE -Uri ("https://api.cloudflare.com/client/v4/zones/" + $CloudflareZoneId + "/dns_records/" + $rec.id) | Out-Null
  }
}

function Ensure-ApexRedirectRecord {
  Write-Host "Ensuring proxied apex A record..." -ForegroundColor Cyan
  $records = Get-DnsRecords

  $apexA = @($records | Where-Object { $_.name -eq $Domain -and $_.type -eq 'A' })
  $apexCname = @($records | Where-Object { $_.name -eq $Domain -and $_.type -eq 'CNAME' })
  $apexAaaa = @($records | Where-Object { $_.name -eq $Domain -and $_.type -eq 'AAAA' })

  if ($apexCname.Count -gt 0) {
    Remove-Records -Records $apexCname -Reason "apex must use proxied A for HTTP redirect"
  }

  if ($apexAaaa.Count -gt 0) {
    Remove-Records -Records $apexAaaa -Reason "remove apex AAAA to avoid redirect mismatch"
  }

  $body = @{
    type = 'A'
    name = $Domain
    content = $ApexRedirectIPv4
    proxied = $true
    ttl = 1
  }

  if ($apexA.Count -eq 0) {
    Write-Host ("Creating proxied apex A " + $Domain + " -> " + $ApexRedirectIPv4) -ForegroundColor Green
    Invoke-CF -Method POST -Uri ("https://api.cloudflare.com/client/v4/zones/" + $CloudflareZoneId + "/dns_records") -Body $body | Out-Null
  } else {
    $keep = $apexA[0]
    if ($apexA.Count -gt 1) {
      Remove-Records -Records ($apexA | Select-Object -Skip 1) -Reason "duplicate apex A records"
    }
    Write-Host ("Updating proxied apex A " + $Domain + " -> " + $ApexRedirectIPv4) -ForegroundColor Green
    Invoke-CF -Method PUT -Uri ("https://api.cloudflare.com/client/v4/zones/" + $CloudflareZoneId + "/dns_records/" + $keep.id) -Body $body | Out-Null
  }
}

function Ensure-CnameRecord {
  param([string]$Name, [string]$Target)

  $records = Get-DnsRecords
  $existing = @($records | Where-Object { $_.type -eq 'CNAME' -and $_.name -eq $Name })

  if ($existing.Count -gt 1) {
    $keep = $existing[0]
    Remove-Records -Records ($existing | Select-Object -Skip 1) -Reason "duplicate CNAME records"
    $existing = @($keep)
  }

  $body = @{
    type = 'CNAME'
    name = $Name
    content = $Target
    proxied = $true
    ttl = 1
  }

  if ($existing.Count -eq 1) {
    Write-Host ("Updating CNAME " + $Name + " -> " + $Target) -ForegroundColor Green
    Invoke-CF -Method PUT -Uri ("https://api.cloudflare.com/client/v4/zones/" + $CloudflareZoneId + "/dns_records/" + $existing[0].id) -Body $body | Out-Null
  } else {
    Write-Host ("Creating CNAME " + $Name + " -> " + $Target) -ForegroundColor Green
    Invoke-CF -Method POST -Uri ("https://api.cloudflare.com/client/v4/zones/" + $CloudflareZoneId + "/dns_records") -Body $body | Out-Null
  }
}

function Ensure-TxtRecord {
  param([string]$Name, [string]$Value)

  $records = Get-DnsRecords
  $existing = @($records | Where-Object { $_.type -eq 'TXT' -and $_.name -eq $Name })

  if ($existing.Count -gt 1) {
    $keep = $existing[0]
    Remove-Records -Records ($existing | Select-Object -Skip 1) -Reason "duplicate TXT records"
    $existing = @($keep)
  }

  $body = @{
    type = 'TXT'
    name = $Name
    content = $Value
    ttl = 1
  }

  if ($existing.Count -eq 1) {
    Write-Host ("Updating TXT " + $Name) -ForegroundColor Green
    Invoke-CF -Method PUT -Uri ("https://api.cloudflare.com/client/v4/zones/" + $CloudflareZoneId + "/dns_records/" + $existing[0].id) -Body $body | Out-Null
  } else {
    Write-Host ("Creating TXT " + $Name) -ForegroundColor Green
    Invoke-CF -Method POST -Uri ("https://api.cloudflare.com/client/v4/zones/" + $CloudflareZoneId + "/dns_records") -Body $body | Out-Null
  }
}

function Show-DnsAudit {
  $records = Get-DnsRecords | Where-Object {
    $_.name -eq $Domain -or $_.name -eq $WwwDomain -or $_.name -eq $RailwayVerifyTxtName
  }

  Write-Host ""
  Write-Host "=== DNS AUDIT ===" -ForegroundColor Cyan
  $records | Sort-Object name, type | Format-Table type, name, content, proxied, ttl -AutoSize
}

function Ensure-RedirectRule {
  $phase = 'http_request_dynamic_redirect'
  $description = "Apex to WWW redirect for " + $Domain

  Write-Host ("Ensuring redirect rule in phase " + $phase + "...") -ForegroundColor Cyan

  $entry = Invoke-CF -Method GET -Uri ("https://api.cloudflare.com/client/v4/zones/" + $CloudflareZoneId + "/rulesets/phases/" + $phase + "/entrypoint")
  $ruleset = $entry.result

  $ruleExpression = '(http.request.full_uri wildcard "https://' + $Domain + '/*")'
  $targetExpression = 'wildcard_replace(http.request.full_uri, "https://' + $Domain + '/*", "https://' + $WwwDomain + '/${1}")'

  $rule = @{
    ref = 'apex-to-www'
    description = $description
    expression = $ruleExpression
    action = 'redirect'
    action_parameters = @{
      from_value = @{
        target_url = @{
          expression = $targetExpression
        }
        status_code = 301
        preserve_query_string = $true
      }
    }
    enabled = $true
  }

  if ($ruleset -and $ruleset.id) {
    $newRules = @()
    $found = $false

    foreach ($r in $ruleset.rules) {
      if ($r.ref -eq 'apex-to-www' -or $r.description -eq $description) {
        $newRules += $rule
        $found = $true
      } else {
        $newRules += $r
      }
    }

    if (-not $found) {
      $newRules += $rule
    }

    Write-Host "Updating redirect ruleset" -ForegroundColor Green
    Invoke-CF -Method PUT -Uri ("https://api.cloudflare.com/client/v4/zones/" + $CloudflareZoneId + "/rulesets/" + $ruleset.id) -Body @{ rules = $newRules } | Out-Null
  } else {
    Write-Host "Creating redirect ruleset" -ForegroundColor Green
    Invoke-CF -Method POST -Uri ("https://api.cloudflare.com/client/v4/zones/" + $CloudflareZoneId + "/rulesets") -Body @{
      name = 'apex redirect ruleset'
      kind = 'zone'
      phase = $phase
      rules = @($rule)
    } | Out-Null
  }

  Write-Host ""
  Write-Host "=== RULESET AUDIT ===" -ForegroundColor Cyan
  $entry2 = Invoke-CF -Method GET -Uri ("https://api.cloudflare.com/client/v4/zones/" + $CloudflareZoneId + "/rulesets/phases/" + $phase + "/entrypoint")
  $entry2.result.rules |
    Where-Object { $_.description -eq $description -or $_.ref -eq 'apex-to-www' } |
    ConvertTo-Json -Depth 20 |
    Write-Host
}

if ($ApplyDns) {
  Ensure-ApexRedirectRecord
  Ensure-CnameRecord -Name $WwwDomain -Target $RailwayTarget
  Ensure-TxtRecord -Name $RailwayVerifyTxtName -Value $RailwayVerifyTxtValue
  Show-DnsAudit
}

if ($ApplyRedirect) {
  Ensure-RedirectRule
}

Start-Sleep -Seconds 10

Write-Host ""
Write-Host "=== VERIFY ===" -ForegroundColor Cyan
curl.exe -I ("https://" + $Domain)
curl.exe -I ("https://" + $WwwDomain)
curl.exe -I ("https://" + $WwwDomain + "/health")
