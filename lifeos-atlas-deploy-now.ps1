param(
  [string]$PackagePath = "$HOME\Downloads\lifeos-atlas-complete-buildout",
  [string]$RepoPath = "C:\Users\PC\lifeos-work\annual-payment-service-Life-OS-Alas",
  [string]$Branch = "main",
  [string]$CommitMessage = "LifeOS Atlas canonical package handoff"
)

$ErrorActionPreference = 'Stop'

Write-Host "== LifeOS Atlas deploy-now ==" -ForegroundColor Cyan

if (-not (Test-Path $PackagePath)) {
  throw "PackagePath not found: $PackagePath"
}
if (-not (Test-Path $RepoPath)) {
  throw "RepoPath not found: $RepoPath"
}
if (-not (Test-Path (Join-Path $RepoPath '.git'))) {
  throw "RepoPath is not a Git repo: $RepoPath"
}

$items = @('public','scripts','docs','server.js','package.json','package-lock.json','railway.json','.env.example')
foreach ($item in $items) {
  $src = Join-Path $PackagePath $item
  if (Test-Path $src) {
    $dst = Join-Path $RepoPath $item
    if (Test-Path $dst) {
      Remove-Item $dst -Recurse -Force
    }
    Copy-Item $src $dst -Recurse -Force
    Write-Host "Copied $item" -ForegroundColor Green
  }
}

Set-Location $RepoPath
if ((Test-Path '.env.example') -and (-not (Test-Path '.env'))) {
  Copy-Item '.env.example' '.env'
  Write-Host 'Created .env from .env.example' -ForegroundColor Yellow
}

npm install
npm run validate

git add .
try {
  git commit -m $CommitMessage
} catch {
  Write-Host 'No new commit created, continuing to push.' -ForegroundColor Yellow
}
git push origin $Branch

Write-Host ''
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host '1. Let Railway redeploy from the pushed branch.' -ForegroundColor Cyan
Write-Host '2. Verify https://lifeosatlas.com => 301 to https://www.lifeosatlas.com/' -ForegroundColor Cyan
Write-Host '3. Verify https://www.lifeosatlas.com => 200' -ForegroundColor Cyan
Write-Host '4. Verify https://www.lifeosatlas.com/health => 200' -ForegroundColor Cyan
