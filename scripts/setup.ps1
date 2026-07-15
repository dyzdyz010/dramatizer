[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $repoRoot ".env"

if (Test-Path -LiteralPath $envPath) {
    foreach ($line in Get-Content -LiteralPath $envPath) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -ne 2) { throw "Invalid .env line: $($parts[0])" }
        [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1], "Process")
    }
}

docker compose -f (Join-Path $repoRoot "infra\docker-compose.yml") up -d --wait
if ($LASTEXITCODE -ne 0) { throw "PostgreSQL startup failed" }

Push-Location (Join-Path $repoRoot "app")
try {
    mix.bat deps.get
    if ($LASTEXITCODE -ne 0) { throw "mix deps.get failed" }
    mix.bat assets.setup
    if ($LASTEXITCODE -ne 0) { throw "mix assets.setup failed" }
    mix.bat ecto.create
    if ($LASTEXITCODE -ne 0) { throw "mix ecto.create failed" }
    mix.bat ecto.migrate
    if ($LASTEXITCODE -ne 0) { throw "mix ecto.migrate failed" }
} finally {
    Pop-Location
}

Write-Host "Dramatizer local dependencies are ready."
