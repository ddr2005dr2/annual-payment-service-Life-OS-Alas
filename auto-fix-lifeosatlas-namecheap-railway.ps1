param(
  [string]$Domain = "lifeosatlas.com",
  [string]$RailwayTarget = "tar7s1zk.up.railway.app.",
  [string]$NamecheapApiUser = $env:NAMECHEAP_API_USER,
  [string]$NamecheapApiKey = $env:NAMECHEAP_API_KEY,
  [string]$NamecheapUsername = $env:NAMECHEAP_USERNAME,
  [string]$NamecheapClientIp = $env:NAMECHEAP_CLIENT_IP,
  [string]$RailwayToken = $env:RAILWAY_TOKEN,
  [string]$ProjectId = $env:RAILWAY_PROJECT_ID,
  [string]$EnvironmentId = $env:RAILWAY_ENVIRONMENT_ID,
  [string]$ServiceId = $env:RAILWAY_SERVICE_ID,
  [switch]$DryRun,
  [switch]$SkipRailway
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
  param(
    [string]$Command,
    [hashtable]$Parameters
  )
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
    if (-not [string]::IsNullOrWhiteSpace($h.TTL)) { $body["TTL$i"] = $h.TTL } else { $body["TTL$i"] = '60' }
    if ($h.RecordType -eq 'MX' -and -not [string]::IsNullOrWhiteSpace($h.MXPref)) { $body["MXPref$i"] = $h.MXPref }
    $i++
  }
  Invoke-NamecheapApi -Command 'namecheap.domains.dns.setHosts' -Parameters $body
}
