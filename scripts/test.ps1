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
    mix.bat test
    if ($LASTEXITCODE -ne 0) { throw "mix test failed" }
} finally {
    Pop-Location
}
