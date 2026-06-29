param(
  [string]$SourceRoot,
  [string]$TargetRoot,
  [string]$Branch = "main",
  [switch]$Commit,
  [switch]$Push,
  [string]$CommitMessage = "Deploy canonical LifeOS Atlas public package"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step($m) {
  Write-Host "`n=== $m ===" -ForegroundColor Cyan
}

function Require-Path($p, $label) {
  if ([string]::IsNullOrWhiteSpace($p)) { throw "$label is required." }
  if (-not (Test-Path $p)) { throw "$label not found: $p" }
}

function Ensure-Dir($p) {
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

function Copy-Clean($from, $to) {
  Ensure-Dir $to
  Get-ChildItem -Path $to -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  Copy-Item -Path (Join-Path $from '*') -Destination $to -Recurse -Force
}

Require-Path $SourceRoot "SourceRoot"
Require-Path $TargetRoot "TargetRoot"
Require-Path (Join-Path $SourceRoot 'app\lifeos-atlas-canonical.html') "Canonical app entry"
Require-Path (Join-Path $SourceRoot 'public') "Public pages folder"

$targetPublic = Join-Path $TargetRoot 'public'
$targetApp = Join-Path $TargetRoot 'app'
$targetConfig = Join-Path $TargetRoot 'config'
$targetContent = Join-Path $TargetRoot 'content'
$targetDocs = Join-Path $TargetRoot 'docs'

Write-Step "Preparing target structure"
Ensure-Dir $targetPublic
Ensure-Dir $targetApp
Ensure-Dir $targetConfig
Ensure-Dir $targetContent
Ensure-Dir $targetDocs

Write-Step "Replacing public package"
Copy-Clean (Join-Path $SourceRoot 'public') $targetPublic
Copy-Clean (Join-Path $SourceRoot 'app') $targetApp
Copy-Clean (Join-Path $SourceRoot 'config') $targetConfig
Copy-Clean (Join-Path $SourceRoot 'content') $targetContent
Copy-Clean (Join-Path $SourceRoot 'docs') $targetDocs
Copy-Item (Join-Path $SourceRoot 'README.md') (Join-Path $TargetRoot 'README.md') -Force

Write-Step "Writing deployment pointer"
@"
ENTRY_POINT=app/lifeos-atlas-canonical.html
PUBLIC_SITE_MODE=canonical
DEPLOYED_AT=$(Get-Date -Format s)
"@ | Set-Content -Path (Join-Path $TargetRoot 'deploy-pointer.env') -Encoding UTF8

$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
  Push-Location $TargetRoot
  try {
    $inside = (& git rev-parse --is-inside-work-tree 2>$null)
    if ($inside -eq 'true') {
      Write-Step "Git status"
      & git status --short
      if ($Commit) {
        Write-Step "Git add/commit"
        & git add .
        & git commit -m $CommitMessage
      }
      if ($Push) {
        Write-Step "Git push"
        & git push origin $Branch
      }
    } else {
      Write-Host "Not a git repository. Files were copied, but no commit/push was attempted." -ForegroundColor Yellow
    }
  } finally {
    Pop-Location
  }
} else {
  Write-Host "Git not installed. Files were copied only." -ForegroundColor Yellow
}

Write-Step "Done"
Write-Host "Target updated: $TargetRoot" -ForegroundColor Green
Write-Host "Entry point: app/lifeos-atlas-canonical.html" -ForegroundColor Green
