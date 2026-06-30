param(
    [string]$Domain = "lifeosatlas.com",
    [string]$WwwDomain = "www.lifeosatlas.com",
    [string]$RailwayPublicHost = "annual-payment-service-life-os-alas-production.up.railway.app",
    [string]$RailwayTarget = "smlqeiav.up.railway.app",
    [string]$RailwayVerifyTxtName = "_railway-verify.www.lifeosatlas.com",
    [string]$RailwayVerifyTxtValue = "railway-verify=f70647c5653a0516bd8aeeabef7bc99aa70496c8cb4b37c5324ad46024f606be",
    [string]$ApexRedirectIp = "192.0.2.1",
    [string]$ExpectedAppPath = "/app/lifeos-atlas-canonical.html",
    [string]$CloudflareApiToken
)

$ErrorActionPreference = 'Stop'

function Section($t){ Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Pass($m){ Write-Host "[PASS] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host "[FAIL] $m" -ForegroundColor Red }
function Info($m){ Write-Host "[INFO] $m" -ForegroundColor Gray }

function Get-Token {
    if (-not $script:CloudflareApiToken -or [string]::IsNullOrWhiteSpace($script:CloudflareApiToken)) {
        $secure = Read-Host "Paste Cloudflare API token" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $script:CloudflareApiToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    if ([string]::IsNullOrWhiteSpace($script:CloudflareApiToken)) { throw 'Cloudflare API token is required.' }
}

function CfApi {
    param([string]$Method,[string]$Uri,[object]$Body)
    Get-Token
    $headers = @{ Authorization = "Bearer $script:CloudflareApiToken"; 'Content-Type' = 'application/json' }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $json = $Body | ConvertTo-Json -Depth 30
        Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $json
    } else {
        Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }
}

function Get-ZoneId {
    Info "Looking up Zone ID for $Domain..."
    $resp = CfApi -Method GET -Uri "https://api.cloudflare.com/client/v4/zones?name=$Domain"
    if (-not $resp.success -or -not $resp.result -or $resp.result.Count -eq 0) { throw "Unable to find Cloudflare zone for $Domain" }
    $id = $resp.result[0].id
    Pass "Found Zone ID: $id"
    return $id
}

function Get-DnsRecords([string]$ZoneId){ (CfApi -Method GET -Uri "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records?per_page=100").result }

function Remove-Record([string]$ZoneId,[string]$RecordId,[string]$Reason){
    CfApi -Method DELETE -Uri "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records/$RecordId" | Out-Null
    Pass "Deleted record: $Reason"
}

function Upsert-Record {
    param([string]$ZoneId,[string]$Type,[string]$Name,[string]$Content,[Nullable[bool]]$Proxied,[int]$Ttl = 1)
    $records = Get-DnsRecords -ZoneId $ZoneId | Where-Object { $_.type -eq $Type -and $_.name -eq $Name }
    $body = @{ type = $Type; name = $Name; content = $Content; ttl = $Ttl }
    if ($null -ne $Proxied) { $body.proxied = $Proxied }
    if ($records) {
        $record = $records | Select-Object -First 1
        $needsUpdate = ($record.content -ne $Content) -or (($null -ne $Proxied) -and ($record.proxied -ne $Proxied))
        if ($needsUpdate) {
            CfApi -Method PUT -Uri "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records/$($record.id)" -Body $body | Out-Null
            Pass "Updated $Type $Name -> $Content"
        } else {
            Pass "No change needed for $Type $Name"
        }
    } else {
        CfApi -Method POST -Uri "https://api.cloudflare.com/client/v4/zones/$ZoneId/dns_records" -Body $body | Out-Null
        Pass "Created $Type $Name -> $Content"
    }
}

function Ensure-Dns([string]$ZoneId){
    Section 'APPLY DNS'
    $records = Get-DnsRecords -ZoneId $ZoneId
    $conflictingCname = $records | Where-Object { $_.type -eq 'CNAME' -and $_.name -eq $Domain }
    foreach ($rec in $conflictingCname) { Remove-Record -ZoneId $ZoneId -RecordId $rec.id -Reason "conflicting apex CNAME $($rec.content)" }
    $conflictingAaaa = $records | Where-Object { $_.type -eq 'AAAA' -and $_.name -eq $Domain }
    foreach ($rec in $conflictingAaaa) { Remove-Record -ZoneId $ZoneId -RecordId $rec.id -Reason "apex AAAA $($rec.content) removed to avoid redirect mismatch" }
    Upsert-Record -ZoneId $ZoneId -Type 'A' -Name $Domain -Content $ApexRedirectIp -Proxied $true
    Upsert-Record -ZoneId $ZoneId -Type 'CNAME' -Name $WwwDomain -Content $RailwayTarget -Proxied $true
    Upsert-Record -ZoneId $ZoneId -Type 'TXT' -Name $RailwayVerifyTxtName -Content $RailwayVerifyTxtValue -Proxied $null
}

function Get-Ruleset([string]$ZoneId){ CfApi -Method GET -Uri "https://api.cloudflare.com/client/v4/zones/$ZoneId/rulesets/phases/http_request_dynamic_redirect/entrypoint" }

function Ensure-Redirect([string]$ZoneId){
    Section 'APPLY REDIRECT'
    $expression = '(http.request.full_uri wildcard "https://' + $Domain + '/*")'
    $targetExpression = 'wildcard_replace(http.request.full_uri, "https://' + $Domain + '/*", "https://' + $WwwDomain + '/${1}")'
    $existing = $null
    try { $existing = (Get-Ruleset -ZoneId $ZoneId).result } catch { $existing = $null }
    if (-not $existing -or -not $existing.id) {
        $body = @{ name = 'Default Redirect Ruleset'; kind = 'zone'; phase = 'http_request_dynamic_redirect'; rules = @(@{ ref = 'apex-to-www'; description = 'Apex to WWW redirect for ' + $Domain; expression = $expression; action = 'redirect'; action_parameters = @{ from_value = @{ status_code = 301; target_url = @{ expression = $targetExpression }; preserve_query_string = $true } }; enabled = $true }) }
        CfApi -Method POST -Uri "https://api.cloudflare.com/client/v4/zones/$ZoneId/rulesets" -Body $body | Out-Null
        Pass 'Created redirect ruleset and apex-to-www rule'
        return
    }
    $rules = @($existing.rules)
    $match = $rules | Where-Object { $_.ref -eq 'apex-to-www' } | Select-Object -First 1
    $rule = @{ ref = 'apex-to-www'; description = 'Apex to WWW redirect for ' + $Domain; expression = $expression; action = 'redirect'; action_parameters = @{ from_value = @{ status_code = 301; target_url = @{ expression = $targetExpression }; preserve_query_string = $true } }; enabled = $true }
    if ($match) {
        $match.description = $rule.description
        $match.expression = $rule.expression
        $match.action = $rule.action
        $match.action_parameters = $rule.action_parameters
        $match.enabled = $true
    } else {
        $rules += $rule
    }
    $body = @{ id = $existing.id; name = $existing.name; kind = $existing.kind; phase = $existing.phase; rules = $rules }
    CfApi -Method PUT -Uri "https://api.cloudflare.com/client/v4/zones/$ZoneId/rulesets/$($existing.id)" -Body $body | Out-Null
    Pass 'Updated redirect ruleset'
}

function Purge-Cache([string]$ZoneId){
    Section 'CACHE PURGE'
    $files = @(
        'https://' + $Domain + '/',
        'https://' + $WwwDomain + '/',
        'https://' + $WwwDomain + '/health',
        'https://' + $WwwDomain + $ExpectedAppPath,
        'https://' + $RailwayPublicHost + '/',
        'https://' + $RailwayPublicHost + $ExpectedAppPath
    )
    CfApi -Method POST -Uri "https://api.cloudflare.com/client/v4/zones/$ZoneId/purge_cache" -Body @{ files = $files } | Out-Null
    Pass 'Purged Cloudflare cache for public and origin-facing URLs'
}

function CurlHead([string]$Url){ curl.exe -I -sS $Url }
function Contains([string]$Text,[string]$Needle){ $Text -like ('*' + $Needle + '*') }

function Verify-All {
    Section 'VERIFY'
    $publicApex = 'https://' + $Domain
    $publicWww = 'https://' + $WwwDomain
    $publicHealth = 'https://' + $WwwDomain + '/health'
    $publicApp = 'https://' + $WwwDomain + $ExpectedAppPath
    $railwayRoot = 'https://' + $RailwayPublicHost
    $railwayApp = 'https://' + $RailwayPublicHost + $ExpectedAppPath

    $a = CurlHead $publicApex
    $w = CurlHead $publicWww
    $h = CurlHead $publicHealth
    $p = CurlHead $publicApp
    $r = CurlHead $railwayRoot
    $ra = CurlHead $railwayApp

    Write-Host $a; Write-Host ''; Write-Host $w; Write-Host ''; Write-Host $h; Write-Host ''; Write-Host $p; Write-Host ''; Write-Host $r; Write-Host ''; Write-Host $ra

    if ((Contains $a '301') -and (Contains $a ('Location: https://' + $WwwDomain + '/'))) { Pass 'Public apex redirect verified' } else { Fail 'Public apex redirect failed' }
    if (Contains $w '200') { Pass 'Public www returned 200' } else { Fail 'Public www failed' }
    if (Contains $h '200') { Pass 'Public /health returned 200' } else { Fail 'Public /health failed' }
    if (Contains $r '200') { Pass 'Railway public host root returned 200' } else { Warn 'Railway public host root did not return 200' }

    if (Contains $p '200') {
        Pass ('Public ' + $ExpectedAppPath + ' returned 200')
    } elseif (Contains $p '404') {
        Fail ('Public ' + $ExpectedAppPath + ' returned 404')
    } else {
        Warn ('Public ' + $ExpectedAppPath + ' returned unexpected response')
    }

    if (Contains $ra '200') {
        Pass ('Railway public host ' + $ExpectedAppPath + ' returned 200')
    } elseif (Contains $ra '404') {
        Fail ('Railway public host ' + $ExpectedAppPath + ' returned 404')
    } else {
        Warn ('Railway public host ' + $ExpectedAppPath + ' returned unexpected response')
    }

    Section 'ROOT CAUSE'
    if ((Contains $p '404') -and (Contains $ra '404')) {
        Fail 'The failing /app path is missing at the Railway origin itself. This is an application deploy/routing problem, not a DNS or Cloudflare problem.'
        Write-Host 'Immediate fix required in app code/deploy: either publish a real file at /app/lifeos-atlas-canonical.html, or add SPA/deep-link fallback routing on the Railway app.' -ForegroundColor Yellow
    } elseif ((Contains $p '404') -and (Contains $ra '200')) {
        Fail 'Origin serves the app path but the public domain does not. That points to caching/proxy/routing mismatch in front of origin.'
    } elseif (Contains $p '200') {
        Pass 'Public app path is healthy.'
    }
}

function Audit-Dns([string]$ZoneId){
    Section 'DNS AUDIT'
    Get-DnsRecords -ZoneId $ZoneId | Sort-Object type, name | Select-Object type,name,content,proxied | Format-Table -AutoSize
}

$zoneId = Get-ZoneId
Audit-Dns -ZoneId $zoneId
Ensure-Dns -ZoneId $zoneId
Ensure-Redirect -ZoneId $zoneId
Purge-Cache -ZoneId $zoneId
Audit-Dns -ZoneId $zoneId
Verify-All
