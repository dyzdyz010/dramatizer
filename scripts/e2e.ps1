[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$envPath = Join-Path $repoRoot ".env"
$appRoot = Join-Path $repoRoot "app"
$e2eRoot = Join-Path $repoRoot "e2e"
$artifactRoot = Join-Path $repoRoot "output\playwright"
$assetRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot "var\e2e-assets"))
$varRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot "var"))
$database = "dramatizer_e2e"
$container = "dramatizer-postgres"
$port = 4100
$server = $null

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

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
}

function Stop-ProcessTree {
    param([Parameter(Mandatory = $true)][int]$TargetProcessId)

    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $TargetProcessId" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        Stop-ProcessTree -TargetProcessId $child.ProcessId
    }
    Stop-Process -Id $TargetProcessId -Force -ErrorAction SilentlyContinue
}

Import-DramatizerEnv

$venvPython = Join-Path $appRoot ".venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $venvPython)) {
    throw "Python media environment is missing. Run scripts/setup.ps1 first."
}

if (-not $assetRoot.StartsWith($varRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean an E2E asset directory outside var: $assetRoot"
}

if (Test-Path -LiteralPath $assetRoot) {
    Remove-Item -LiteralPath $assetRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null

[Environment]::SetEnvironmentVariable("DRAMATIZER_PROVIDER", "fake", "Process")
[Environment]::SetEnvironmentVariable("DRAMATIZER_ASSET_STORE_ROOT", $assetRoot, "Process")
[Environment]::SetEnvironmentVariable("DRAMATIZER_PYTHON", $venvPython, "Process")
[Environment]::SetEnvironmentVariable("DATABASE_URL", "ecto://postgres:postgres@127.0.0.1:55432/$database", "Process")
[Environment]::SetEnvironmentVariable("PORT", $port.ToString(), "Process")
[Environment]::SetEnvironmentVariable("DRAMATIZER_E2E_URL", "http://127.0.0.1:$port", "Process")

try {
    Invoke-Checked "docker" @("compose", "-f", (Join-Path $repoRoot "infra\docker-compose.yml"), "up", "-d", "--wait") "PostgreSQL startup failed"
    Invoke-Checked "docker" @("exec", $container, "dropdb", "--if-exists", "--force", "-U", "postgres", $database) "Dropping the E2E database failed"
    Invoke-Checked "docker" @("exec", $container, "createdb", "-U", "postgres", $database) "Creating the E2E database failed"

    Push-Location $appRoot
    try {
        Invoke-Checked "mix.bat" @("ecto.migrate") "E2E database migration failed"
        Invoke-Checked "mix.bat" @("assets.build") "E2E asset build failed"
    } finally {
        Pop-Location
    }

    $stdout = Join-Path $artifactRoot "phoenix.stdout.log"
    $stderr = Join-Path $artifactRoot "phoenix.stderr.log"
    $server = Start-Process -FilePath "cmd.exe" `
        -ArgumentList @("/d", "/c", "mix.bat phx.server") `
        -WorkingDirectory $appRoot `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -WindowStyle Hidden `
        -PassThru

    $ready = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        if ($server.HasExited) {
            throw "Phoenix exited before E2E became ready. See $stdout and $stderr"
        }
        try {
            $response = Invoke-WebRequest -Uri "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 2
            if ($response.StatusCode -eq 200) {
                $ready = $true
                break
            }
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $ready) { throw "Phoenix did not become ready on port $port" }

    Push-Location $e2eRoot
    try {
        Invoke-Checked "npm.cmd" @("install") "Installing Playwright dependencies failed"
        Invoke-Checked "npx.cmd" @("playwright", "install", "chromium") "Installing Playwright Chromium failed"
        Invoke-Checked "npm.cmd" @("test") "Playwright E2E failed"
    } finally {
        Pop-Location
    }
} finally {
    if ($server -and -not $server.HasExited) {
        Stop-ProcessTree -TargetProcessId $server.Id
    }
}
