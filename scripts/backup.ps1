[CmdletBinding()]
param(
    [string]$Destination,
    [string]$Database = "dramatizer_dev",
    [string]$Container = "dramatizer-postgres",
    [int]$Port = 4000
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $repoRoot ".env"
$checkpoint = Join-Path $repoRoot "var\write-checkpoint.json"

function Import-DramatizerEnv {
    if (-not (Test-Path -LiteralPath $envPath)) { return }
    foreach ($line in Get-Content -LiteralPath $envPath) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -ne 2) { throw "Invalid .env entry: $($parts[0])" }
        [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1], "Process")
    }
}

Import-DramatizerEnv

if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    throw "Phoenix is listening on port $Port. Stop it before creating a consistent backup."
}

if (Test-Path -LiteralPath $checkpoint) {
    throw "A write checkpoint already exists: $checkpoint"
}

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $Destination = Join-Path $repoRoot "var\backups\$stamp"
}

$Destination = [IO.Path]::GetFullPath($Destination)
$assetRoot = if ($env:DRAMATIZER_ASSET_STORE_ROOT) {
    [IO.Path]::GetFullPath($env:DRAMATIZER_ASSET_STORE_ROOT)
} else {
    [IO.Path]::GetFullPath((Join-Path $repoRoot "var\assets"))
}

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $checkpoint) | Out-Null

$checkpointBody = @{
    state = "writes_paused"
    operation = "backup"
    started_at = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json
[IO.File]::WriteAllText($checkpoint, $checkpointBody)

try {
    docker compose -f (Join-Path $repoRoot "infra\docker-compose.yml") up -d --wait
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL startup failed" }

    Push-Location (Join-Path $repoRoot "app")
    try {
        mix.bat dramatizer.assets.verify
        if ($LASTEXITCODE -ne 0) { throw "AssetStore verification failed before backup" }
        mix.bat dramatizer.backup.manifest --output (Join-Path $Destination "manifest.json")
        if ($LASTEXITCODE -ne 0) { throw "Manifest generation failed" }
    } finally {
        Pop-Location
    }

    $containerDump = "/tmp/dramatizer-$([guid]::NewGuid().ToString('N')).dump"
    docker exec $Container pg_dump -U postgres -d $Database --format=custom --no-owner --no-acl --file=$containerDump
    if ($LASTEXITCODE -ne 0) { throw "pg_dump failed" }
    docker cp "${Container}:${containerDump}" (Join-Path $Destination "database.dump")
    if ($LASTEXITCODE -ne 0) { throw "Copying database dump failed" }
    docker exec $Container rm -f $containerDump

    $backupAssetRoot = Join-Path $Destination "assets"
    New-Item -ItemType Directory -Force -Path $backupAssetRoot | Out-Null
    $sourceFinal = Join-Path $assetRoot "final"
    if (Test-Path -LiteralPath $sourceFinal) {
        Copy-Item -LiteralPath $sourceFinal -Destination $backupAssetRoot -Recurse -Force
    }

    $metadata = @{
        schema_version = 1
        database = $Database
        created_at = (Get-Date).ToUniversalTime().ToString("o")
        asset_directory = "assets/final"
        dump = "database.dump"
        manifest = "manifest.json"
    } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $Destination "backup.json"), $metadata)

    Write-Host "Backup verified and complete: $Destination"
} finally {
    if (Test-Path -LiteralPath $checkpoint) { Remove-Item -LiteralPath $checkpoint -Force }
    Write-Host "Write checkpoint released; local writes may resume."
}
