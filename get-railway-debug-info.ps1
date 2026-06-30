$ErrorActionPreference = 'SilentlyContinue'

Write-Host '=== Railway Debug Info Collector ===' -ForegroundColor Cyan
$repo = Get-Location
Write-Host ("Working directory: " + $repo.Path)

Write-Host "`n=== Top-level files ===" -ForegroundColor Yellow
Get-ChildItem -Force | Select-Object Mode,Length,LastWriteTime,Name | Format-Table -AutoSize

Write-Host "`n=== package.json scripts ===" -ForegroundColor Yellow
if (Test-Path '.\package.json') {
    try {
        $pkg = Get-Content '.\package.json' -Raw | ConvertFrom-Json
        $pkg | ConvertTo-Json -Depth 20
    } catch {
        Get-Content '.\package.json' -TotalCount 250
    }
} else {
    Write-Host 'No package.json found.' -ForegroundColor DarkYellow
}

Write-Host "`n=== Procfile ===" -ForegroundColor Yellow
if (Test-Path '.\Procfile') {
    Get-Content '.\Procfile'
} else {
    Write-Host 'No Procfile found.' -ForegroundColor DarkYellow
}

Write-Host "`n=== Dockerfile(s) ===" -ForegroundColor Yellow
Get-ChildItem -Recurse -Force -Include 'Dockerfile','dockerfile','Dockerfile.*','*.Dockerfile' |
    ForEach-Object {
        Write-Host ("--- " + $_.FullName) -ForegroundColor Green
        Get-Content $_.FullName -TotalCount 250
    }

Write-Host "`n=== railway.json / nixpacks.toml ===" -ForegroundColor Yellow
foreach ($f in @('.\railway.json','.\nixpacks.toml','.\nixpacks.json','.\vercel.json')) {
    if (Test-Path $f) {
        Write-Host ("--- " + (Resolve-Path $f)) -ForegroundColor Green
        Get-Content $f -TotalCount 250
    }
}

Write-Host "`n=== Environment variable references ===" -ForegroundColor Yellow
$patterns = @(
    'process.env.PORT',
    'PORT',
    '0.0.0.0',
    'localhost',
    'app.listen',
    'server.listen',
    'uvicorn',
    'gunicorn',
    'flask run',
    'next start',
    'vite preview'
)

Get-ChildItem -Recurse -File -Include *.js,*.cjs,*.mjs,*.ts,*.tsx,*.py,*.rb,*.go,*.php,*.java,*.cs,*.json,*.toml,*.yml,*.yaml,Procfile,Dockerfile* |
    ForEach-Object {
        $file = $_.FullName
        foreach ($p in $patterns) {
            Select-String -Path $file -Pattern $p -SimpleMatch | ForEach-Object {
                "{0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim()
            }
        }
    }

Write-Host "`n=== Likely entry files ===" -ForegroundColor Yellow
Get-ChildItem -Recurse -File -Include server.js,index.js,app.js,main.py,manage.py,Procfile,Dockerfile,package.json |
    Select-Object FullName

Write-Host "`n=== Done ===" -ForegroundColor Cyan