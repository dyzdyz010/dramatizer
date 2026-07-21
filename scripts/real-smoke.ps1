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

    # The proposal-driven gate derives its shape from the AI-confirmed
    # VisualDesign and ShotPlan; the acceptance test bounds them, and the
    # summary must stay internally consistent instead of matching fixed counts.
    $references = [int]$Summary.reference_images
    $shotCandidates = [int]$Summary.shot_candidates
    $clips = [int]$Summary.final_clips

    if ($references -lt 1 -or $references -gt 10) { throw "Expected between 1 and 10 reference images." }
    if ($clips -lt 1 -or $clips -gt 4) { throw "Expected between 1 and 4 final clips." }
    if ($shotCandidates -ne ($clips * 2)) { throw "Expected exactly 2 candidates per final shot." }
    if ([int]$Summary.technical_qc_reports -ne ($references + $shotCandidates)) {
        throw "Expected one technical QC report per generated image."
    }
    if ([int]$Summary.semantic_qc_reports -ne ($references + $shotCandidates)) {
        throw "Expected one semantic QC report per generated image."
    }

    # Floor: 6 analysis nodes + 3 stage proposals + one image and one semantic
    # QC request per generated candidate + one image-prompt proposal per unique
    # authority (each reference slot, and one per shot because same-shot
    # candidates reuse the successful prompt attempt). Retries/repairs add more.
    $minRequests = 6 + 3 + 2 * ($references + $shotCandidates) + ($references + $clips)
    if ([int]$Summary.provider_requests -lt $minRequests) {
        throw "Expected at least $minRequests persisted provider requests."
    }
    if ([int]$Summary.provider_request_ids -lt ($minRequests - 2)) {
        throw "Expected at least $($minRequests - 2) captured provider request IDs."
    }

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

    $costValue = if ([string]::IsNullOrWhiteSpace([string]$Summary.actual_cost_micros)) {
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
