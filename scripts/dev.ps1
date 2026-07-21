[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $repoRoot ".env"
$checkpoint = Join-Path $repoRoot "var\write-checkpoint.json"

if (Test-Path -LiteralPath $checkpoint) {
    throw "Writes are checkpointed for backup/restore. Finish that operation before starting Phoenix."
}

if (Test-Path -LiteralPath $envPath) {
    foreach ($line in Get-Content -LiteralPath $envPath) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -ne 2) { throw "Invalid .env entry: $($parts[0])" }
        [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1], "Process")
    }
}

docker compose -f (Join-Path $repoRoot "infra\docker-compose.yml") up -d --wait
if ($LASTEXITCODE -ne 0) { throw "PostgreSQL startup failed" }

$venvPython = Join-Path $repoRoot "app\.venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $venvPython)) {
    throw "Python media environment is missing. Run scripts/setup.ps1 first."
}
[Environment]::SetEnvironmentVariable("DRAMATIZER_PYTHON", $venvPython, "Process")

$port = if ($env:PORT) { [int]$env:PORT } else { 4000 }
$provider = if ($env:DRAMATIZER_PROVIDER) { $env:DRAMATIZER_PROVIDER } else { "fake" }

if ($provider -notin @("fake", "openai")) {
    throw "DRAMATIZER_PROVIDER must be 'fake' or 'openai'; got '$provider'. Refusing to fall back to fake silently."
}
if ($provider -eq "openai" -and [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
    throw "DRAMATIZER_PROVIDER=openai requires OPENAI_API_KEY in .env. Refusing to fall back to fake silently."
}

Push-Location (Join-Path $repoRoot "app")
try {
    mix.bat ecto.migrate
    if ($LASTEXITCODE -ne 0) { throw "Database migration failed" }
    mix.bat assets.build
    if ($LASTEXITCODE -ne 0) { throw "Asset build failed" }
    Write-Host "Dramatizer: http://127.0.0.1:$port"
    Write-Host "Provider mode: $provider"
    mix.bat phx.server
    if ($LASTEXITCODE -ne 0) { throw "Phoenix server exited with an error" }
} finally {
    Pop-Location
}
