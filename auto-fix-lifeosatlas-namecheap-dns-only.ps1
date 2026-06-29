param(
  [string]$Domain = 'lifeosatlas.com',
  [string]$RailwayTarget = 'tar7s1zk.up.railway.app.',
  [string]$WwwRailwayVerifyValue = 'railway-verify=PASTE_WWW_TOKEN_HERE',
  [string]$NamecheapApiUser = $env:NAMECHEAP_API_USER,
  [string]$NamecheapApiKey = $env:NAMECHEAP_API_KEY,
  [string]$NamecheapUsername = $env:NAMECHEAP_USERNAME,
  [string]$NamecheapClientIp = $env:NAMECHEAP_CLIENT_IP,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Section {
  param([string]$Name)
  Write-Host ""
  Write-Host (("=" * 12) + " " + $Name + " " + ("=" * 12))
}

function Split-Domain {
  param([string]$Fqdn)
  $parts = $Fqdn.Split('.')
  if ($parts.Count -lt 2) { throw "Invalid domain: $Fqdn" }
  [pscustomobject]@{
    SLD = $parts[$parts.Count - 2]
    TLD = $parts[$parts.Count - 1]
  }
}

function Invoke-NamecheapApi {
  param([string]$Command,[hashtable]$Parameters)
  foreach ($v in @($NamecheapApiUser,$NamecheapApiKey,$NamecheapUsername,$NamecheapClientIp)) {
    if ([string]::IsNullOrWhiteSpace($v)) {
      throw 'Missing Namecheap API credentials. Set NAMECHEAP_API_USER, NAMECHEAP_API_KEY, NAMECHEAP_USERNAME, NAMECHEAP_CLIENT_IP.'
    }
  }
  $common = @{
    ApiUser = $NamecheapApiUser
    ApiKey = $NamecheapApiKey
    UserName = $NamecheapUsername
    ClientIp = $NamecheapClientIp
    Command = $Command
  }
  foreach ($k in $Parameters.Keys) { $common[$k] = $Parameters[$k] }
  Invoke-RestMethod -Method Post -Uri 'https://api.namecheap.com/xml.response' -Body $common -ContentType 'application/x-www-form-urlencoded'
}

function Get-NamecheapHosts {
  $d = Split-Domain $Domain
  Invoke-NamecheapApi -Command 'namecheap.domains.dns.getHosts' -Parameters @{ SLD = $d.SLD; TLD = $d.TLD }
}

function Convert-HostsXmlToObjects {
  param($XmlResult)
  $hosts = @()
  $nodes = @($XmlResult.ApiResponse.CommandResponse.DomainDNSGetHostsResult.host)
  foreach ($h in $nodes) {
    $hosts += [pscustomobject]@{
      HostName = [string]$h.Name
      RecordType = [string]$h.Type
      Address = [string]$h.Address
      TTL = [string]$h.TTL
      MXPref = [string]$h.MXPref
    }
  }
  $hosts
}

function Set-NamecheapHosts {
  param([array]$Hosts)
  $d = Split-Domain $Domain
  $body = @{ SLD = $d.SLD; TLD = $d.TLD }
  $i = 1
  foreach ($h in $Hosts) {
    $body["HostName$i"] = $h.HostName
    $body["RecordType$i"] = $h.RecordType
    $body["Address$i"] = $h.Address
    $body["TTL$i"] = if ([string]::IsNullOrWhiteSpace($h.TTL)) { '60' } else { $h.TTL }
    if ($h.RecordType -eq 'MX' -and -not [string]::IsNullOrWhiteSpace($h.MXPref)) { $body["MXPref$i"] = $h.MXPref }
    $i++
  }
  Invoke-NamecheapApi -Command 'namecheap.domains.dns.setHosts' -Parameters $body
}

Write-Section 'CURRENT HOSTS'
$xml = Get-NamecheapHosts
$hosts = @(Convert-HostsXmlToObjects -XmlResult $xml)
$hosts | Format-Table -AutoSize

Write-Section 'BUILD TARGET HOSTS'
$newHosts = @($hosts)
$newHosts = @($newHosts | Where-Object { -not (($_.HostName -eq '@') -and ($_.RecordType -eq 'CNAME')) })
$newHosts = @($newHosts | Where-Object { -not (($_.HostName -eq '@') -and ($_.RecordType -eq 'ALIAS')) })
$newHosts = @($newHosts | Where-Object { -not (($_.HostName -eq '@') -and ($_.RecordType -eq 'URL')) })
$newHosts = @($newHosts | Where-Object { -not (($_.HostName -eq 'www') -and ($_.RecordType -eq 'CNAME')) })
$newHosts = @($newHosts | Where-Object { -not (($_.HostName -eq '_railway-verify.www') -and ($_.RecordType -eq 'TXT')) })
$newHosts += [pscustomobject]@{ HostName = 'www'; RecordType = 'CNAME'; Address = $RailwayTarget; TTL = '60'; MXPref = '' }
$newHosts += [pscustomobject]@{ HostName = '_railway-verify.www'; RecordType = 'TXT'; Address = $WwwRailwayVerifyValue; TTL = '60'; MXPref = '' }
$newHosts += [pscustomobject]@{ HostName = '@'; RecordType = 'URL'; Address = ('https://www.' + $Domain); TTL = '60'; MXPref = '' }
$newHosts | Format-Table -AutoSize

Write-Section 'APPLY'
if ($DryRun) {
  Write-Host 'Dry run enabled. No DNS changes sent.'
} else {
  $resp = Set-NamecheapHosts -Hosts $newHosts
  Write-Host 'DNS update submitted to Namecheap.'
  if ($resp.ApiResponse.Errors -and $resp.ApiResponse.Errors.Error) {
    $resp.ApiResponse.Errors.Error | ForEach-Object { if ($_.'#text') { Write-Host ('ERROR=' + $_.'#text') } }
  }
}

Write-Section 'DONE'
Write-Host 'Expected result:'
Write-Host '- www points to Railway'
Write-Host '- _railway-verify.www TXT exists'
Write-Host '- root redirects to https://www.lifeosatlas.com'
