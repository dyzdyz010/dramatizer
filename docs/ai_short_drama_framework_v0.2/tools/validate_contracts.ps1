param(
    [string]$ContractRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$ContractRoot = [IO.Path]::GetFullPath($ContractRoot)
$schemaDirectory = Join-Path $ContractRoot 'schemas'
$exampleDirectory = Join-Path $ContractRoot 'examples'
$jsonSchemaAssembly = Join-Path $PSHOME 'JsonSchema.Net.dll'

if (-not (Test-Path -LiteralPath $jsonSchemaAssembly)) {
    throw "JsonSchema.Net.dll was not found under PSHOME. Run this validator with PowerShell 7."
}

Add-Type -Path $jsonSchemaAssembly

$options = [Json.Schema.EvaluationOptions]::Default
$options.EvaluateAs = [Json.Schema.SpecVersion]::Draft202012
$options.OutputFormat = [Json.Schema.OutputFormat]::List
$options.RequireFormatValidation = $true
$options.ValidateAgainstMetaSchema = $true

$schemas = @{}
$schemaIds = @{}

Get-ChildItem -LiteralPath $schemaDirectory -Filter '*.json' | Sort-Object Name | ForEach-Object {
    $raw = [IO.File]::ReadAllText($_.FullName)
    $json = [System.Text.Json.Nodes.JsonNode]::Parse($raw)
    $schemaId = [string]$json['$id']

    if ([string]::IsNullOrWhiteSpace($schemaId)) {
        throw "Schema $($_.Name) has no `$id."
    }
    if ($schemaIds.ContainsKey($schemaId)) {
        throw "Duplicate schema `$id '$schemaId' in $($_.Name) and $($schemaIds[$schemaId])."
    }

    $schema = [Json.Schema.JsonSchema]::FromText($raw)
    $schemas[$_.Name] = $schema
    $schemaIds[$schemaId] = $_.Name
    $options.SchemaRegistry.Register($schema)
}

$cases = @(
    @{ Example = 'shot-plan-example.json';       Schema = 'shot-plan-revision.schema.json' },
    @{ Example = 'continuity-example.json';      Schema = 'continuity.schema.json' },
    @{ Example = 'workflow-run-example.json';    Schema = 'workflow-runtime.schema.json' },
    @{ Example = 'provider-request-snapshot-example.json'; Schema = 'provider-request-snapshot.schema.json' },
    @{ Example = 'provider-routing-example.json'; Schema = 'provider-routing.schema.json' },
    @{ Example = 'rights-gate-example.json';     Schema = 'rights-gate.schema.json' },
    @{ Example = 'quality-report-example.json';  Schema = 'quality-report.schema.json' }
)

$failures = [System.Collections.Generic.List[string]]::new()

foreach ($case in $cases) {
    $examplePath = Join-Path $exampleDirectory $case.Example
    if (-not (Test-Path -LiteralPath $examplePath)) {
        $failures.Add("Missing example: $($case.Example)")
        continue
    }
    if (-not $schemas.ContainsKey($case.Schema)) {
        $failures.Add("Missing schema: $($case.Schema)")
        continue
    }

    $instance = [System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($examplePath))
    $result = $schemas[$case.Schema].Evaluate($instance, $options)
    if ($result.IsValid) {
        Write-Host "PASS  $($case.Example) -> $($case.Schema)"
    }
    else {
        $invalidDetails = @($result.Details | Where-Object { -not $_.IsValid -and $_.HasErrors })
        $detailLines = @($invalidDetails | Select-Object -First 50 | ForEach-Object {
            $instancePath = '/' + ($_.InstanceLocation -join '/')
            $messages = @($_.Errors.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join '; '
            "  ${instancePath}: $messages"
        })
        if ($invalidDetails.Count -gt 50) {
            $detailLines += "  ... $($invalidDetails.Count - 50) additional validation details omitted"
        }
        $failures.Add("Schema validation failed: $($case.Example) -> $($case.Schema)`n$($detailLines -join "`n")")
    }
}

function Get-ExampleNode([string]$name) {
    $path = Join-Path $exampleDirectory $name
    $node = [System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($path))
    Write-Output -NoEnumerate $node
}

function Set-CheckWaiver([System.Text.Json.Nodes.JsonNode]$instance, [string]$checkCodesJson) {
    $waiver = [System.Text.Json.Nodes.JsonNode]::Parse(@'
{
  "permission": "quality.waive.check",
  "permission_policy_revision": {
    "revision_id": "quality_permission_policy_r1",
    "content_hash": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  },
  "permission_evaluated_at": "2026-07-13T08:12:19Z",
  "reason": "Bounded fixture waiver used to verify the discriminated scope contract.",
  "scope": {
    "scope_type": "check",
    "subject": null,
    "check_codes": []
  },
  "expires_at": "2026-07-14T08:12:19Z",
  "audit_event_id": "audit_waiver_contract_fixture",
  "conditions": []
}
'@)
    $waiver['scope']['subject'] = $instance['review_decisions'][0]['subject'].DeepClone()
    $waiver['scope']['check_codes'] = [System.Text.Json.Nodes.JsonNode]::Parse($checkCodesJson)
    $instance['review_decisions'][0]['decision'] = [System.Text.Json.Nodes.JsonValue]::Create('waive')
    $instance['review_decisions'][0]['waiver'] = $waiver
}

function Set-ReleaseGateFixture([System.Text.Json.Nodes.JsonNode]$instance, [string]$availabilityStatus) {
    $instance['scope'] = [System.Text.Json.Nodes.JsonValue]::Create('episode_release')
    $instance['subject']['entity_type'] = [System.Text.Json.Nodes.JsonValue]::Create('timeline_version')
    $instance['release_gate'] = [System.Text.Json.Nodes.JsonNode]::Parse(@"
{
  "release_gate_id": "release_gate_ep01_v1",
  "timeline": {
    "entity_type": "timeline_version",
    "id": "timeline_ep01_v8",
    "content_hash": "sha256:3030303030303030303030303030303030303030303030303030303030303030"
  },
  "export_asset": {
    "entity_type": "export_asset_version",
    "id": "av_export_ep01_v1",
    "content_hash": "sha256:3131313131313131313131313131313131313131313131313131313131313131"
  },
  "gate_input_closure_hash": "sha256:2525252525252525252525252525252525252525252525252525252525252525",
  "quality_report_id": "quality_report_release_ep01_v1",
  "rights_gate_snapshot": {
    "entity_type": "rights_gate_snapshot",
    "id": "rgs_release_ep01_allowed",
    "content_hash": "sha256:3232323232323232323232323232323232323232323232323232323232323232"
  },
  "asset_availability_snapshot": [
    {
      "asset_version_id": "av_export_ep01_v1",
      "availability_revision_id": "availability_export_ep01_r1",
      "availability_hash": "sha256:3333333333333333333333333333333333333333333333333333333333333333",
      "status": "$availabilityStatus",
      "evaluated_at": "2026-07-13T09:29:59Z"
    }
  ],
  "review_decision_ids": ["review_candidate_0"],
  "policy_revision": {
    "revision_id": "release_policy_r5",
    "content_hash": "sha256:3434343434343434343434343434343434343434343434343434343434343434"
  },
  "status": "ready",
  "evaluated_at": "2026-07-13T09:30:00Z",
  "valid_until": "2026-07-14T09:30:00Z",
  "blocking_reasons": [],
  "waiver_review_decision_id": null,
  "extensions": []
}
"@)
}

# A valid derived waiver proves that the corresponding empty-scope negative case
# is rejected for its discriminator constraint, not for unrelated fixture damage.
$validWaiverInstance = Get-ExampleNode 'quality-report-example.json'
Set-CheckWaiver $validWaiverInstance '["continuity.hand"]'
$validWaiverResult = $schemas['quality-report.schema.json'].Evaluate($validWaiverInstance, $options)
if ($validWaiverResult.IsValid) {
    Write-Host 'PASS  derived valid check waiver is accepted'
}
else {
    $failures.Add('Derived valid check waiver was unexpectedly rejected')
}

$validReleaseGateInstance = Get-ExampleNode 'quality-report-example.json'
Set-ReleaseGateFixture $validReleaseGateInstance 'available'
$validReleaseGateResult = $schemas['quality-report.schema.json'].Evaluate($validReleaseGateInstance, $options)
if ($validReleaseGateResult.IsValid) {
    Write-Host 'PASS  derived ready ReleaseGate with available assets is accepted'
}
else {
    $failures.Add('Derived ready ReleaseGate with available assets was unexpectedly rejected')
}

$negativeCases = @(
    @{
        Name = 'Directing audio mode cannot name a Provider'; Example = 'shot-plan-example.json'; Schema = 'shot-plan-revision.schema.json'
        Mutate = { param($node) $node['audio_strategy']['mode'] = [System.Text.Json.Nodes.JsonValue]::Create('seedance_native') }
    },
    @{
        Name = 'Generated candidate cannot become dialogue authority'; Example = 'shot-plan-example.json'; Schema = 'shot-plan-revision.schema.json'
        Mutate = { param($node) $node['audio_strategy']['dialogue_authority'] = [System.Text.Json.Nodes.JsonValue]::Create('candidate_until_approved') }
    },
    @{
        Name = 'planned_start snapshot cannot use end boundary'; Example = 'continuity-example.json'; Schema = 'continuity.schema.json'
        Mutate = { param($node) $node['snapshots'][1]['boundary']['position'] = [System.Text.Json.Nodes.JsonValue]::Create('end') }
    },
    @{
        Name = 'accept_observation requires at least one observation'; Example = 'continuity-example.json'; Schema = 'continuity.schema.json'
        Mutate = { param($node) $node['approvals'][0]['input_observation_ids'] = [System.Text.Json.Nodes.JsonNode]::Parse('[]') }
    },
    @{
        Name = 'reject cannot carry an approved snapshot'; Example = 'continuity-example.json'; Schema = 'continuity.schema.json'
        Mutate = { param($node) $node['approvals'][0]['decision'] = [System.Text.Json.Nodes.JsonValue]::Create('reject') }
    },
    @{
        Name = 'Resolved plan cannot carry a denied budget decision'; Example = 'provider-routing-example.json'; Schema = 'provider-routing.schema.json'
        Mutate = { param($node) $node['resolved_execution_plans'][0]['budget_gate']['decision'] = [System.Text.Json.Nodes.JsonValue]::Create('deny') }
    },
    @{
        Name = 'Resolved plan requires a held budget reservation'; Example = 'provider-routing-example.json'; Schema = 'provider-routing.schema.json'
        Mutate = { param($node) $node['resolved_execution_plans'][0]['budget_reservation_status_at_pin'] = [System.Text.Json.Nodes.JsonValue]::Create('released') }
    },
    @{
        Name = 'Resolved plan must bind candidate prefilter evidence'; Example = 'provider-routing-example.json'; Schema = 'provider-routing.schema.json'
        Mutate = { param($node) [void]$node['resolved_execution_plans'][0].AsObject().Remove('candidate_prefilter_snapshot_hash') }
    },
    @{
        Name = 'CandidatePrefilterSnapshot must pin RoutePolicy revision'; Example = 'provider-routing-example.json'; Schema = 'provider-routing.schema.json'
        Mutate = { param($node) [void]$node['candidate_prefilter_snapshots'][0].AsObject().Remove('route_policy_version') }
    },
    @{
        Name = 'rejected prefilter candidate requires a rejection code'; Example = 'provider-routing-example.json'; Schema = 'provider-routing.schema.json'
        Mutate = { param($node) $node['candidate_prefilter_snapshots'][1]['candidate_results'][0]['rejection_codes'] = [System.Text.Json.Nodes.JsonNode]::Parse('[]') }
    },
    @{
        Name = 'manual-review RightsGate requires a HumanTask'; Example = 'rights-gate-example.json'; Schema = 'rights-gate.schema.json'
        Mutate = {
            param($node)
            $manualSnapshot = @($node['rights_gate_snapshots'].AsArray() | Where-Object {
                $_['decision'].ToString() -eq 'manual_review'
            })[0]
            [void]$manualSnapshot.AsObject().Remove('human_task_id')
        }
    },
    @{
        Name = 'Rights HumanTask requires a hard deadline'; Example = 'rights-gate-example.json'; Schema = 'rights-gate.schema.json'
        Mutate = { param($node) [void]$node['human_tasks'][0].AsObject().Remove('hard_deadline_at') }
    },
    @{
        Name = 'expired Rights HumanTask requires its expiration timestamp'; Example = 'rights-gate-example.json'; Schema = 'rights-gate.schema.json'
        Mutate = { param($node) $node['human_tasks'][0]['status'] = [System.Text.Json.Nodes.JsonValue]::Create('deadline_expired') }
    },
    @{
        Name = 'render RightsGate requires internal-export intended use'; Example = 'rights-gate-example.json'; Schema = 'rights-gate.schema.json'
        Mutate = {
            param($node)
            $renderSnapshot = @($node['rights_gate_snapshots'].AsArray() | Where-Object { $_['scope'].ToString() -eq 'render' })[0]
            $renderSnapshot['intended_use']['purpose'] = [System.Text.Json.Nodes.JsonValue]::Create('generation')
        }
    },
    @{
        Name = 'Provider request snapshot must prove secrets were excluded'; Example = 'provider-request-snapshot-example.json'; Schema = 'provider-request-snapshot.schema.json'
        Mutate = { param($node) $node['provider_request_snapshots'][0]['secrets_excluded'] = [System.Text.Json.Nodes.JsonValue]::Create($false) }
    },
    @{
        Name = 'ProviderAttempt must bind a request snapshot'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = { param($node) [void]$node['provider_attempts'][0].AsObject().Remove('provider_request_snapshot_id') }
    },
    @{
        Name = 'required workflow HumanGate requires a hard deadline'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = { param($node) [void]$node['workflow_definition']['nodes'][5]['human_gate'].AsObject().Remove('hard_deadline_seconds') }
    },
    @{
        Name = 'waiting NodeRun must reference its runtime HumanTask'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = { param($node) [void]$node['node_runs'][6].AsObject().Remove('human_task_id') }
    },
    @{
        Name = 'runtime Budget HumanTask requires a hard deadline'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = { param($node) [void]$node['human_tasks'][1].AsObject().Remove('hard_deadline_at') }
    },
    @{
        Name = 'deadline-expired HumanTask requires a timestamp and no active claim'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = {
            param($node)
            $node['human_tasks'][0]['status'] = [System.Text.Json.Nodes.JsonValue]::Create('deadline_expired')
            $node['human_tasks'][0]['claimed_by'] = [System.Text.Json.Nodes.JsonValue]::Create('user_stale_claim')
        }
    },
    @{
        Name = 'waiting HumanTask cannot carry a deadline-expired timestamp'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = { param($node) $node['human_tasks'][0]['deadline_expired_at'] = [System.Text.Json.Nodes.JsonValue]::Create('2026-07-14T08:21:13Z') }
    },
    @{
        Name = 'completed GenerationTask requires candidate prefilter evidence'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = { param($node) [void]$node['generation_tasks'][0].AsObject().Remove('candidate_prefilter_snapshot_hash') }
    },
    @{
        Name = 'AssetVersion cannot exist before finalize'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = { param($node) $node['asset_versions'][0]['finalized'] = [System.Text.Json.Nodes.JsonValue]::Create($false) }
    },
    @{
        Name = 'finalized UploadIntent requires asset id and timestamp'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = {
            param($node)
            [void]$node['upload_intents'][0].AsObject().Remove('asset_version_id')
            [void]$node['upload_intents'][0].AsObject().Remove('finalized_at')
        }
    },
    @{
        Name = 'succeeded candidate slot requires attempts and assets'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = {
            param($node)
            $node['generation_tasks'][0]['candidate_slots'][0]['attempt_ids'] = [System.Text.Json.Nodes.JsonNode]::Parse('[]')
            $node['generation_tasks'][0]['candidate_slots'][0]['asset_version_ids'] = [System.Text.Json.Nodes.JsonNode]::Parse('[]')
        }
    },
    @{
        Name = 'RenderInputManifest requires a current Rights and availability snapshot'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = {
            param($node)
            [void]$node['render_input_manifests'][0].AsObject().Remove('rights_gate_snapshot_id')
            [void]$node['render_input_manifests'][0].AsObject().Remove('asset_availability_snapshot_hash')
        }
    },
    @{
        Name = 'ReleaseManifest cannot be created from a blocked gate'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = { param($node) $node['release_manifests'][0]['release_gate_status_at_creation'] = [System.Text.Json.Nodes.JsonValue]::Create('blocked') }
    },
    @{
        Name = 'ReleaseManifest must bind the canonical ReleaseGate hash'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = { param($node) [void]$node['release_manifests'][0].AsObject().Remove('release_gate_hash') }
    },
    @{
        Name = 'PublishAttempt requires an immediate publication preflight'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = {
            param($node)
            [void]$node['publish_attempts'][0].AsObject().Remove('publication_preflight_hash')
            [void]$node['publish_attempts'][0].AsObject().Remove('preflight_checked_at')
        }
    },
    @{
        Name = 'submitted PublishAttempt cannot carry a failed preflight'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = { param($node) $node['publish_attempts'][0]['publication_preflight_result'] = [System.Text.Json.Nodes.JsonValue]::Create('failed') }
    },
    @{
        Name = 'PublishAttempt must bind current Rights preflight evidence'; Example = 'workflow-run-example.json'; Schema = 'workflow-runtime.schema.json'
        Mutate = { param($node) [void]$node['publish_attempts'][0].AsObject().Remove('rights_gate_snapshot_hash') }
    },
    @{
        Name = 'check waiver scope cannot be empty'; Example = 'quality-report-example.json'; Schema = 'quality-report.schema.json'
        Mutate = { param($node) Set-CheckWaiver $node '[]' }
    },
    @{
        Name = 'ready ReleaseGate rejects quarantined assets'; Example = 'quality-report-example.json'; Schema = 'quality-report.schema.json'
        Mutate = { param($node) Set-ReleaseGateFixture $node 'quarantined' }
    }
)

foreach ($negativeCase in $negativeCases) {
    try {
        $instance = Get-ExampleNode $negativeCase.Example
        & $negativeCase.Mutate $instance
        $result = $schemas[$negativeCase.Schema].Evaluate($instance, $options)
        if ($result.IsValid) {
            $failures.Add("Negative contract case was incorrectly accepted: $($negativeCase.Name)")
        }
        else {
            Write-Host "PASS  rejects: $($negativeCase.Name)"
        }
    }
    catch {
        $failures.Add("Negative contract case could not run: $($negativeCase.Name) -- $($_.Exception.Message)")
    }
}

# Catch orphan example JSON files that are not deliberately mapped above.
$mappedExamples = @($cases | ForEach-Object { $_.Example })
Get-ChildItem -LiteralPath $exampleDirectory -Filter '*.json' | ForEach-Object {
    [void][System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($_.FullName))
    if ($_.Name -notin $mappedExamples) {
        $failures.Add("Unmapped example JSON: $($_.Name)")
    }
}

# Verify local Markdown links so the contract remains navigable after file moves.
Get-ChildItem -LiteralPath $ContractRoot -Recurse -Filter '*.md' | ForEach-Object {
    $markdownPath = $_.FullName
    $content = [IO.File]::ReadAllText($markdownPath)
    $matches = [regex]::Matches($content, '\]\((?!https?://|mailto:|#)(?<target>[^)#]+)(?:#[^)]+)?\)')
    foreach ($match in $matches) {
        $target = $match.Groups['target'].Value.Trim().Trim('<', '>')
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        $resolved = [IO.Path]::GetFullPath((Join-Path $_.DirectoryName $target))
        if (-not (Test-Path -LiteralPath $resolved)) {
            $relativeMarkdown = [IO.Path]::GetRelativePath($ContractRoot, $markdownPath)
            $failures.Add("Broken local link in ${relativeMarkdown}: $target")
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "PASS  $($schemas.Count) schemas have unique ids and valid Draft 2020-12 structure"
Write-Host "PASS  $($cases.Count) mapped examples, $($negativeCases.Count) negative cases, and all local Markdown links"
