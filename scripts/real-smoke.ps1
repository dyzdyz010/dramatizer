[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$appRoot = Join-Path $repoRoot "app"
$envPath = Join-Path $repoRoot ".env"
$varRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot "var"))
$assetRoot = [IO.Path]::GetFullPath((Join-Path $varRoot "real-smoke-assets"))
$outputRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot "output\real-smoke"))
$database = "dramatizer_real_smoke"
$container = "dramatizer-postgres"

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

function Get-RealSmokeSummary {
    param([Parameter(Mandatory = $true)][object[]]$Lines)

    $prefix = "DRAMATIZER_REAL_SMOKE_RESULT="
    $joined = $Lines -join [Environment]::NewLine
    $markerIndex = $joined.LastIndexOf($prefix, [StringComparison]::Ordinal)
    if ($markerIndex -lt 0) { return $null }

    $jsonStart = $markerIndex + $prefix.Length
    $lineEnd = $joined.IndexOf([Environment]::NewLine, $jsonStart, [StringComparison]::Ordinal)
    $json = if ($lineEnd -lt 0) {
        $joined.Substring($jsonStart)
    } else {
        $joined.Substring($jsonStart, $lineEnd - $jsonStart)
    }

    return ($json.Trim() | ConvertFrom-Json)
}

function Assert-RealSmokeSummary {
    param([Parameter(Mandatory = $true)]$Summary)

    if ($Summary.decision -ne "pass") { throw "Real-smoke decision was not pass." }
    if ([int]$Summary.analysis_nodes -ne 6) { throw "Expected exactly 6 analysis nodes." }
    if ([int]$Summary.reference_images -ne 3) { throw "Expected exactly 3 required reference images." }
    if ([int]$Summary.shot_candidates -ne 6) { throw "Expected exactly 6 shot candidates." }
    if ([int]$Summary.final_clips -ne 3) { throw "Expected exactly 3 final clips." }
    if ([int]$Summary.technical_qc_reports -ne 9) { throw "Expected exactly 9 technical QC reports." }
    if ([int]$Summary.semantic_qc_reports -ne 9) { throw "Expected exactly 9 semantic QC reports." }
    if ([int]$Summary.provider_requests -lt 24) { throw "Expected at least 24 persisted provider requests." }
    if ([int]$Summary.provider_request_ids -lt 24) { throw "Expected at least 24 captured provider request IDs." }
    if ([int64]$Summary.usage_units -le 0) { throw "Expected non-zero provider usage." }
    if ([int]$Summary.formal_video.width -ne 1080 -or [int]$Summary.formal_video.height -ne 1920) {
        throw "Formal video dimensions did not match 1080x1920."
    }
}

function Write-RealSmokeSummary {
    param(
        [Parameter(Mandatory = $true)]$Summary,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [switch]$Reused
    )

    $costValue = if ([int]$Summary.actual_cost_entries -eq 0) {
        "unavailable"
    } else {
        $Summary.actual_cost_micros
    }

    $message = (
        "Real smoke: PASS; analysis={0}; references={1}; shot_candidates={2}; clips={3}; " +
        "technical_qc={4}; semantic_qc={5}; requests={6}; request_ids={7}; usage_units={8}; " +
        "actual_cost_entries={9}; actual_cost_micros={10}; video={11}x{12}"
    ) -f @(
        $Summary.analysis_nodes,
        $Summary.reference_images,
        $Summary.shot_candidates,
        $Summary.final_clips,
        $Summary.technical_qc_reports,
        $Summary.semantic_qc_reports,
        $Summary.provider_requests,
        $Summary.provider_request_ids,
        $Summary.usage_units,
        $Summary.actual_cost_entries,
        $costValue,
        $Summary.formal_video.width,
        $Summary.formal_video.height
    )

    Write-Host $message
    if ($Reused) { Write-Host "Evidence mode: reused latest passing real-provider run; use -Force to regenerate." }
    Write-Host "Redacted evidence log: $LogPath"
}

Import-DramatizerEnv

if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
    throw "OPENAI_API_KEY gate failed. Add it to the process environment or gitignored root .env."
}

Write-Host "OPENAI_API_KEY gate: ready (value not displayed)"

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$logPath = Join-Path $outputRoot "real-smoke.log"

if (-not $Force -and (Test-Path -LiteralPath $logPath)) {
    $existingOutput = @(Get-Content -LiteralPath $logPath)
    $existingJoined = $existingOutput -join [Environment]::NewLine

    if ($existingJoined.Contains($env:OPENAI_API_KEY, [StringComparison]::Ordinal)) {
        throw "Secret-leak gate failed; inspect the ignored real-smoke log locally."
    }

    $existingSummary = Get-RealSmokeSummary -Lines $existingOutput
    if ($existingSummary) {
        Assert-RealSmokeSummary -Summary $existingSummary
        Write-RealSmokeSummary -Summary $existingSummary -LogPath $logPath -Reused
        return
    }
}

$venvPython = Join-Path $appRoot ".venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $venvPython)) {
    throw "Python media environment is missing. Run scripts/setup.ps1 first."
}

if (-not $assetRoot.StartsWith($varRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean a real-smoke asset directory outside var."
}

if (Test-Path -LiteralPath $assetRoot) {
    Remove-Item -LiteralPath $assetRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $assetRoot | Out-Null

[Environment]::SetEnvironmentVariable("MIX_ENV", "test", "Process")
[Environment]::SetEnvironmentVariable("DRAMATIZER_PROVIDER", "openai", "Process")
[Environment]::SetEnvironmentVariable("DRAMATIZER_REAL_SMOKE", "1", "Process")
[Environment]::SetEnvironmentVariable("DRAMATIZER_ASSET_STORE_ROOT", $assetRoot, "Process")
[Environment]::SetEnvironmentVariable("DRAMATIZER_PYTHON", $venvPython, "Process")
[Environment]::SetEnvironmentVariable(
    "TEST_DATABASE_URL",
    "ecto://postgres:postgres@127.0.0.1:55432/$database",
    "Process"
)

Invoke-Checked "docker" @(
    "compose", "-f", (Join-Path $repoRoot "infra\docker-compose.yml"), "up", "-d", "--wait"
) "PostgreSQL startup failed"
Invoke-Checked "docker" @(
    "exec", $container, "dropdb", "--if-exists", "--force", "-U", "postgres", $database
) "Dropping the real-smoke database failed"
Invoke-Checked "docker" @(
    "exec", $container, "createdb", "-U", "postgres", $database
) "Creating the real-smoke database failed"

Push-Location $appRoot
try {
    Invoke-Checked "mix.bat" @("ecto.migrate") "Real-smoke database migration failed"

    $testOutput = @(
        & mix.bat test `
            test/dramatizer/acceptance/real_provider_smoke_test.exs `
            --include real_provider `
            --seed 0 `
            --trace 2>&1 | Tee-Object -FilePath $logPath
    )
    $testExit = $LASTEXITCODE
} finally {
    Pop-Location
}

$joinedOutput = $testOutput -join [Environment]::NewLine
if ($joinedOutput.Contains($env:OPENAI_API_KEY, [StringComparison]::Ordinal)) {
    throw "Secret-leak gate failed; inspect the ignored real-smoke log locally."
}

if ($testExit -ne 0) {
    throw "Real OpenAI smoke test failed. See ignored log: $logPath"
}

$summary = Get-RealSmokeSummary -Lines $testOutput
if (-not $summary) { throw "Real-smoke result marker was not emitted." }
Assert-RealSmokeSummary -Summary $summary
Write-RealSmokeSummary -Summary $summary -LogPath $logPath
