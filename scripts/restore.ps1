[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,
    [string]$Database = "dramatizer_dev",
    [string]$Container = "dramatizer-postgres",
    [string]$TargetAssetRoot,
    [int]$Port = 4000,
    [switch]$Force
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

if (-not $Force) { throw "Restore replaces the target database and AssetStore. Re-run with -Force." }
if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    throw "Phoenix is listening on port $Port. Stop it before restore."
}
if (Test-Path -LiteralPath $checkpoint) { throw "A write checkpoint already exists: $checkpoint" }

$Source = [IO.Path]::GetFullPath($Source)
if (-not (Test-Path -LiteralPath (Join-Path $Source "database.dump"))) { throw "database.dump is missing" }
if (-not (Test-Path -LiteralPath (Join-Path $Source "manifest.json"))) { throw "manifest.json is missing" }

if ([string]::IsNullOrWhiteSpace($TargetAssetRoot)) {
    $TargetAssetRoot = if ($env:DRAMATIZER_ASSET_STORE_ROOT) {
        $env:DRAMATIZER_ASSET_STORE_ROOT
    } else {
        Join-Path $repoRoot "var\assets"
    }
}

$TargetAssetRoot = [IO.Path]::GetFullPath($TargetAssetRoot)
$driveRoot = [IO.Path]::GetPathRoot($TargetAssetRoot)
if ($TargetAssetRoot -eq $driveRoot -or $TargetAssetRoot -eq [IO.Path]::GetFullPath($repoRoot)) {
    throw "Unsafe TargetAssetRoot: $TargetAssetRoot"
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $checkpoint) | Out-Null
[IO.File]::WriteAllText($checkpoint, (@{
    state = "writes_paused"
    operation = "restore"
    started_at = (Get-Date).ToUniversalTime().ToString("o")
} | ConvertTo-Json))

try {
    docker compose -f (Join-Path $repoRoot "infra\docker-compose.yml") up -d --wait
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL startup failed" }

    docker exec $Container psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$Database' AND pid <> pg_backend_pid();"
    if ($LASTEXITCODE -ne 0) { throw "Unable to checkpoint database connections" }
    docker exec $Container dropdb -U postgres --if-exists $Database
    if ($LASTEXITCODE -ne 0) { throw "Dropping target database failed" }
    docker exec $Container createdb -U postgres $Database
    if ($LASTEXITCODE -ne 0) { throw "Creating target database failed" }

    $containerDump = "/tmp/dramatizer-restore-$([guid]::NewGuid().ToString('N')).dump"
    docker cp (Join-Path $Source "database.dump") "${Container}:${containerDump}"
    if ($LASTEXITCODE -ne 0) { throw "Copying restore dump failed" }
    docker exec $Container pg_restore -U postgres -d $Database --no-owner --no-acl --exit-on-error $containerDump
    if ($LASTEXITCODE -ne 0) { throw "pg_restore failed" }
    docker exec $Container rm -f $containerDump

    if (Test-Path -LiteralPath $TargetAssetRoot) {
        $verifiedTarget = [IO.Path]::GetFullPath($TargetAssetRoot)
        if ($verifiedTarget -ne $TargetAssetRoot) { throw "Target path verification failed" }
        Remove-Item -LiteralPath $verifiedTarget -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $TargetAssetRoot | Out-Null
    $backupFinal = Join-Path $Source "assets\final"
    if (Test-Path -LiteralPath $backupFinal) {
        Copy-Item -LiteralPath $backupFinal -Destination $TargetAssetRoot -Recurse -Force
    }

    [Environment]::SetEnvironmentVariable("DRAMATIZER_ASSET_STORE_ROOT", $TargetAssetRoot, "Process")
    [Environment]::SetEnvironmentVariable("DATABASE_URL", "ecto://postgres:postgres@127.0.0.1:55432/$Database", "Process")

    Push-Location (Join-Path $repoRoot "app")
    try {
        mix.bat dramatizer.assets.verify
        if ($LASTEXITCODE -ne 0) { throw "Restored AssetStore does not match database references" }
    } finally {
        Pop-Location
    }

    Write-Host "Restore verified: database=$Database asset_root=$TargetAssetRoot"
} finally {
    if (Test-Path -LiteralPath $checkpoint) { Remove-Item -LiteralPath $checkpoint -Force }
    Write-Host "Write checkpoint released; start the application explicitly when ready."
}
