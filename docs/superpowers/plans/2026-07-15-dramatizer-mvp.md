# Dramatizer Text-to-Animatic MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a localhost-only Phoenix/LiveView system that imports a Chinese TXT/Markdown/text-PDF novel, produces confirmable AI drafts and image candidates through the same Fake/real provider path, and exports a traceable H.264/AAC silent vertical Animatic.

**Architecture:** Keep design and operations at the repository root and generate one Phoenix modular monolith in `app/`. PostgreSQL/Oban are the workflow fact source, immutable typed revisions carry production authority, a content-addressed local AssetStore owns media, Req-based OpenAI adapters implement stateless Responses and Images calls, and a versioned Python/FFmpeg worker handles text-PDF extraction, image probes, subtitle rendering, and Animatic assembly.

**Tech Stack:** Elixir 1.20, OTP 28, Phoenix 1.8/LiveView, Ecto/PostgreSQL 17, Oban, Req, Jason, Python 3.14 with pypdf/Pillow, FFmpeg 8, ExUnit, StreamData, Playwright.

## Global Constraints

- The confirmed PRD at `docs/superpowers/specs/2026-07-15-dramatizer-mvp-prd.md` is the scope authority. Do not add auth, RBAC, tenancy, RightsGate, OCR, real video, TTS, music, Suno, cloud deployment, or automatic paid regeneration.
- Execute tasks in order in `feat/dramatizer-mvp`; mark a checkbox only after its listed verification command succeeds. If a design premise fails, stop and amend this plan explicitly before changing direction.
- Use TDD for every custom behavior: add the smallest failing test, run it and observe the expected failure, add minimal code, rerun to green, then refactor while green.
- Generated Phoenix scaffold is the only generated-code exception. Custom migration, context, worker, adapter, LiveView, script, and rendering behavior remains test-first.
- Bind HTTP only to `127.0.0.1`. Store credential reference names only; never persist or print API key/header values.
- `Fake` and `OpenAI` adapters must enter through the same `GenerationSpec -> config -> ProviderRequestSnapshot -> Attempt -> Adapter -> UploadIntent -> AssetVersion -> QC -> SelectionDecision` orchestration.
- No provider call may rely on implicit remote conversation state. Every request must be reconstructable from the local immutable snapshot.
- A provider success does not imply QC pass or selection. A semantic QC result never auto-selects and never triggers paid generation.
- The real-provider acceptance gate runs only after all offline tests and Fake E2E pass. If `OPENAI_API_KEY` is absent, pause there and ask the user to add it to root `.env`.
- Commit after each numbered task with the prescribed message so progress survives interruption.

---

### Task 1: Scaffold the application and reproducible local runtime

**Requirements:** Phase 0 foundation; localhost deployment topology.

**Files:**

- Create: `app/**` via Phoenix 1.8 scaffold
- Modify: `app/mix.exs`
- Modify: `app/config/config.exs`
- Modify: `app/config/dev.exs`
- Modify: `app/config/test.exs`
- Modify: `app/config/runtime.exs`
- Modify: `app/lib/dramatizer/application.ex`
- Create: `infra/docker-compose.yml`
- Create: `.env.example`
- Modify: `.gitignore`
- Create: `scripts/setup.ps1`
- Create: `scripts/test.ps1`
- Test: `app/test/dramatizer/runtime_config_test.exs`

**Contract:**

```elixir
config :dramatizer,
  asset_store_root: Path.expand("../var/assets", __DIR__),
  media_worker_python: "python",
  ffmpeg_path: "ffmpeg",
  ffprobe_path: "ffprobe",
  provider_mode: :fake
```

- [x] Generate `app/` with `mix phx.new app --app dramatizer --module Dramatizer --database postgres --binary-id --no-mailer --no-agents-md --install`.
- [x] Add `oban`, `req`, and `stream_data`; configure Ecto primary/foreign keys as UUIDs and Oban queues `workflow: 5`, `generation: 3`, `media: 2`, `qc: 3`.
- [x] Write `runtime_config_test.exs` first to require localhost binding, externalized DB URL, provider mode, and absolute asset root; observe failure, implement configuration, then observe green.
- [x] Add a PostgreSQL 17 Compose service named `dramatizer-postgres` on host port 55432 with an isolated named volume and a healthcheck.
- [x] Add PowerShell setup/test entrypoints that load a gitignored root `.env`, start only the scoped Compose service, install Python requirements later when present, create/migrate DBs, and propagate non-zero exits.
- [x] Verify: `docker compose -f infra/docker-compose.yml up -d --wait`; `Push-Location app; mix deps.get; mix ecto.create; mix test test/dramatizer/runtime_config_test.exs; Pop-Location`.
- [x] Commit: `chore: scaffold Phoenix runtime`.

### Task 2: Establish projects, layered configuration, prompts, and immutable revisions

**Requirements:** FR-001–FR-005, FR-030–FR-032.

**Files:**

- Create: `app/priv/repo/migrations/*_create_core_tables.exs`
- Create: `app/lib/dramatizer/projects/{project,production_profile,model_override,prompt_appendix}.ex`
- Create: `app/lib/dramatizer/projects.ex`
- Create: `app/lib/dramatizer/revisions/{draft,revision}.ex`
- Create: `app/lib/dramatizer/revisions.ex`
- Create: `app/lib/dramatizer/generation/config_resolver.ex`
- Create: `app/lib/dramatizer/prompts/{catalog,composer}.ex`
- Create: `app/priv/prompts/v1/*.md`
- Test: `app/test/dramatizer/projects_test.exs`
- Test: `app/test/dramatizer/revisions_test.exs`
- Test: `app/test/dramatizer/generation/config_resolver_test.exs`
- Test: `app/test/dramatizer/prompts/composer_test.exs`

**Public interfaces:**

```elixir
Projects.create_project(attrs)
Projects.effective_profile(project, episode_override \\ %{})
ConfigResolver.resolve(task_type, project, task_override \\ %{})
Prompts.Composer.compose(task_type, appendix_revision, assigns)
Revisions.create_draft(project, kind, payload, provenance)
Revisions.confirm_draft(draft_id)
Revisions.derive_draft(revision_id)
```

- [x] Add failing migrations/context tests for multiple projects, archive/rename, 9:16 defaults, Project/Episode override precedence, task/Project/system model precedence, task-scoped Appendix revisions, and immutable confirmed revisions.
- [x] Implement `projects`, `production_profiles`, `model_overrides`, `prompt_appendices`, `drafts`, and `revisions` with database constraints for kind/status/hash uniqueness and immutable revisions (changeset exposes no update operation).
- [x] Add hidden versioned CorePrompt files for people/relations, places/props/world, events/timeline, entity merge, episode candidates, conflict check, directing proposal, image prompt, structured repair, and semantic QC.
- [x] Compose `CorePrompt + Appendix` in fixed order, save component hashes, and assert one task appendix cannot leak into another.
- [x] Add deterministic canonical JSON hashing for profile/config/revision snapshots.
- [x] Verify: `Push-Location app; mix ecto.migrate; mix test test/dramatizer/projects_test.exs test/dramatizer/revisions_test.exs test/dramatizer/generation/config_resolver_test.exs test/dramatizer/prompts/composer_test.exs; Pop-Location`.
- [x] Commit: `feat: add project configuration and revision authority`.

### Task 3: Implement AssetStore staging, finalize, lineage, and media probes

**Requirements:** FR-043, FR-053, FR-060, core asset invariants.

**Files:**

- Create: `app/priv/repo/migrations/*_create_asset_tables.exs`
- Create: `app/lib/dramatizer/assets/{upload_intent,asset_version,store}.ex`
- Create: `app/lib/dramatizer/assets.ex`
- Create: `app/lib/dramatizer/media/worker.ex`
- Create: `app/priv/media_worker/worker.py`
- Create: `app/priv/media_worker/requirements.txt`
- Test: `app/test/dramatizer/assets_test.exs`
- Test: `app/test/dramatizer/media/worker_test.exs`
- Fixture: `app/test/support/fixtures/media/*`

**Public interfaces:**

```elixir
Assets.create_upload_intent(project, attrs)
Assets.stage_bytes(intent, bytes)
Assets.finalize(intent, lineage \\ %{})
Assets.import_file(project, path, attrs)
Assets.verify(asset_version)
Media.Worker.run(command, payload)
```

- [x] Write failing tests that prove no `AssetVersion` exists before finalize, final paths are SHA-256 content-addressed, duplicate bytes deduplicate blobs but not lineage records, parent assets remain immutable, invalid media leaves a recoverable intent, and no staging file is exposed downstream.
- [x] Implement `upload_intents` and `asset_versions` with stable idempotency keys, parent asset reference, exact size/MIME/hash metadata, and atomic same-volume rename into `final/<sha-prefix>/<sha>`.
- [x] Implement versioned JSON-lines Python commands `probe_image`, `probe_video`, `extract_pdf_text`, and later `render_animatic`; reject unknown protocol versions/commands.
- [x] Add deterministic technical image probe using Pillow/FFprobe and map failures to stable error codes.
- [x] Verify: `Push-Location app; mix test test/dramatizer/assets_test.exs test/dramatizer/media/worker_test.exs; Pop-Location`.
- [x] Commit: `feat: add content addressed asset finalization`.

### Task 4: Implement recoverable workflow, attempts, events, and costs

**Requirements:** FR-020 runtime semantics, FR-050, FR-073–FR-074, FR-090–FR-092.

**Files:**

- Create: `app/priv/repo/migrations/*_create_workflow_generation_cost_tables.exs`
- Create: `app/lib/dramatizer/workflow/{workflow_run,node_run,inbox_message,outbox_event}.ex`
- Create: `app/lib/dramatizer/workflow.ex`
- Create: `app/lib/dramatizer/workflow/jobs/node_job.ex`
- Create: `app/lib/dramatizer/generation/{generation_spec,provider_request_snapshot,attempt,adapter}.ex`
- Create: `app/lib/dramatizer/generation.ex`
- Create: `app/lib/dramatizer/costs/{cost_entry,budget}.ex`
- Create: `app/lib/dramatizer/costs.ex`
- Test: `app/test/dramatizer/workflow_test.exs`
- Test: `app/test/dramatizer/generation_test.exs`
- Test: `app/test/dramatizer/costs_test.exs`

**State contracts:**

```text
NodeRun: blocked -> queued -> running -> succeeded|failed|cancelled|superseded
Attempt: prepared -> submitted -> succeeded|failed|timed_out|unknown_remote_state
```

- [x] Write failing tests for allowed transitions, no terminal-state regression, required-parent blocking, retry appending an Attempt, stable idempotency under duplicate submission/callback, inbox deduplication, outbox insertion in the same transaction, and crash/restart recovery from record IDs.
- [x] Implement workflow tables and explicit transition functions using optimistic lock/version checks; Oban args carry only `node_run_id`.
- [x] Implement `generation_specs`, request snapshots, and attempts; redact `authorization`, `api_key`, `token`, and configured secret patterns before persistence/logging.
- [x] Implement estimate/reservation/actual cost entries; unknown actual cost remains `nil`; optional project budget reservation happens transactionally before submission.
- [x] Verify concurrency behavior with `Task.async_stream` duplicate calls and SQL unique constraints.
- [x] Verify: `Push-Location app; mix test test/dramatizer/workflow_test.exs test/dramatizer/generation_test.exs test/dramatizer/costs_test.exs; Pop-Location`.
- [x] Commit: `feat: add recoverable workflow and provider attempts`.

### Task 5: Complete the Fake three-shot vertical slice through selection

**Requirements:** FR-050 Fake behavior, FR-051, AT-001–AT-002 foundation.

**Files:**

- Create: `app/lib/dramatizer/generation/adapters/fake.ex`
- Create: `app/lib/dramatizer/generation/orchestrator.ex`
- Create: `app/lib/dramatizer/quality/{quality_report,selection_decision}.ex`
- Create: `app/lib/dramatizer/quality.ex`
- Create: `app/priv/repo/migrations/*_create_quality_tables.exs`
- Create: `app/test/support/fixtures/fake_episode.ex`
- Test: `app/test/dramatizer/generation/fake_adapter_test.exs`
- Test: `app/test/dramatizer/fake_vertical_slice_test.exs`

**Fault profile:**

```elixir
%{delay_ms: 0, fail_on_attempt: nil, timeout_on_attempt: nil,
  duplicate_callbacks: 0, out_of_order_callbacks: false, cost_micros: 0}
```

- [x] Test first that Fake emits deterministic portrait PNG candidates for one episode/scene/three shots through the production orchestration path, with two candidates per Shot and distinct logical candidate indexes.
- [x] Implement fault injection for delay, failure, timeout, duplicate/out-of-order callback, and synthetic cost without branching around snapshots/attempts/assets.
- [x] Test technical QC hard-blocking, non-blocking semantic fixture evidence, explicit selection only, one active decision per slot, and retention of unselected candidates.
- [x] Run a fail/resume matrix for every node and assert successful siblings/attempts/costs are not duplicated.
- [x] Verify: `Push-Location app; mix test test/dramatizer/generation/fake_adapter_test.exs test/dramatizer/fake_vertical_slice_test.exs; Pop-Location`.
- [x] Commit: `feat: run fake generation through production contracts`.

### Task 6: Parse TXT, Markdown, and text-layer PDFs as immutable sources

**Requirements:** FR-010–FR-012, AT-003 parser scope.

**Files:**

- Create: `app/priv/repo/migrations/*_create_source_tables.exs`
- Create: `app/lib/dramatizer/sources/{source_document,source_revision,parser,token_estimator}.ex`
- Create: `app/lib/dramatizer/sources.ex`
- Test: `app/test/dramatizer/sources/parser_test.exs`
- Test: `app/test/dramatizer/sources_test.exs`
- Fixture: `app/test/support/fixtures/sources/{novel.txt,novel.md,text.pdf,image_only.pdf}`

**Public interfaces:**

```elixir
Sources.import(project, path, role \\ :volume)
Sources.replace(source_document, path)
Sources.analysis_input(project, revision_ids)
TokenEstimator.preflight(text, resolved_model, reserved_tokens)
```

- [x] Test UTF-8/BOM normalization, newline normalization, TXT character offsets, Markdown preserved content, PDF page locators, and `text_layer_required` for image-only PDFs; do not add OCR fallback.
- [x] Persist immutable normalized UTF-8 source blobs through AssetStore and `source_revisions`; allow volume/companion/replacement while leaving old analysis branches replayable.
- [x] Implement a conservative, versioned whole-document token estimator and explicit `document_too_large` with measured/reserved/context values; prove input is never truncated or chunked.
- [x] Verify: `Push-Location app; python -m pip install -r priv/media_worker/requirements.txt; mix test test/dramatizer/sources/parser_test.exs test/dramatizer/sources_test.exs; Pop-Location`.
- [x] Commit: `feat: import whole text novels with source locators`.

### Task 7: Implement the analysis DAG, schemas, repair loop, and OpenAI Responses adapter

**Requirements:** FR-020–FR-022, FR-050 text adapter, AT-003–AT-004.

**Files:**

- Create: `app/priv/repo/migrations/*_create_analysis_tables.exs`
- Create: `app/lib/dramatizer/analysis/{analysis_snapshot,dag,schemas,validator}.ex`
- Create: `app/lib/dramatizer/analysis.ex`
- Create: `app/lib/dramatizer/analysis/jobs/analysis_node_job.ex`
- Create: `app/lib/dramatizer/generation/adapters/openai_responses.ex`
- Create: `app/priv/analysis_schemas/*.json`
- Test: `app/test/dramatizer/analysis/dag_test.exs`
- Test: `app/test/dramatizer/analysis/validator_test.exs`
- Test: `app/test/dramatizer/generation/openai_responses_test.exs`
- Fixture: `app/test/support/fixtures/openai/responses/*.json`

**DAG nodes:** `people_relations`, `places_props_world`, `events_timeline`, `entity_merge`, `episode_candidates`, `conflict_check`.

- [x] Test three full-text roots can run independently; required descendants stay blocked; retry only appends to failed node; final immutable snapshot contains all exact source revisions and task snapshots.
- [x] Add strict JSON Schemas with `source_grounded|inferred|creative` and source locators; validate JSON Schema first, then reference integrity, uniqueness, range, and domain rules with stable JSON-pointer error paths.
- [x] Test invalid JSON, dangling references, and missing locators produce at most two structured repair Attempts, then success or a stable failed node.
- [x] Implement `OpenAIResponses` with Req against `POST /v1/responses`, `store: false`, `text.format.type=json_schema`, strict schema, model/effort from resolved config, request ID/usage capture, timeout/error mapping, and output extraction from response items.
- [x] Contract-test the adapter with a local Plug stub; no live key is needed in this task.
- [x] Verify: `Push-Location app; mix test test/dramatizer/analysis test/dramatizer/generation/openai_responses_test.exs; Pop-Location`.
- [x] Commit: `feat: analyze whole novels with repairable structured outputs`.

### Task 8: Materialize episodes and compile confirmed production revisions

**Requirements:** FR-030–FR-032, FR-040–FR-042.

**Files:**

- Create: `app/lib/dramatizer/narrative.ex`
- Create: `app/lib/dramatizer/visuals.ex`
- Create: `app/lib/dramatizer/directing.ex`
- Create: `app/lib/dramatizer/directing/compiler.ex`
- Create: `app/lib/dramatizer/directing/canonical_json.ex`
- Create: `app/priv/generation_templates/v1/*.json.eex`
- Test: `app/test/dramatizer/narrative_test.exs`
- Test: `app/test/dramatizer/visuals_test.exs`
- Test: `app/test/dramatizer/directing/compiler_test.exs`

**Revision kinds:** `narrative`, `visual_design`, `reference_set`, `shot_plan`.

- [x] Test selecting an episode candidate materializes only its dependency closure into editable drafts and cannot make AI data authoritative before confirmation.
- [x] Test role/scene/prop variants and reference requirements: recurring characters always require confirmed slots; recurring/key locations/props require sets; one-off non-key items may remain textual.
- [x] Implement default character/location/prop slot templates and explicit primary `AssetVersion` per slot.
- [x] Test deterministic `ShotPlanRevision -> GenerationSpecRevision`: equal exact revision/profile/template/compiler/config inputs produce byte-identical canonical payload/hash; any exact input change changes the hash.
- [x] Freeze source, Narrative, VisualDesign, ReferenceSet, ShotPlan, ProductionProfile, prompt/compiler/template versions in compiled specs.
- [x] Verify: `Push-Location app; mix test test/dramatizer/narrative_test.exs test/dramatizer/visuals_test.exs test/dramatizer/directing/compiler_test.exs; Pop-Location`.
- [x] Commit: `feat: compile confirmed revisions into generation specs`.

### Task 9: Add real image generation/editing and reference workflows

**Requirements:** FR-040–FR-043, FR-050–FR-053, AT-005–AT-006 adapter contracts.

**Files:**

- Create: `app/lib/dramatizer/generation/adapters/openai_images.ex`
- Create: `app/lib/dramatizer/visuals/reference_workflow.ex`
- Create: `app/lib/dramatizer/generation/image_prompt_compiler.ex`
- Test: `app/test/dramatizer/generation/openai_images_test.exs`
- Test: `app/test/dramatizer/visuals/reference_workflow_test.exs`
- Fixture: `app/test/support/fixtures/openai/images/*.json`

**HTTP contracts:**

```text
POST /v1/images/generations  JSON: model, prompt, size, quality, output_format
POST /v1/images/edits        multipart: model, image[], prompt, optional mask
```

- [x] Contract-test generation and multipart edit requests against a local Plug stub, including `gpt-image-2`, base64 decode, request ID/error mapping, and metadata/usage capture.
- [x] Implement default counts (reference 4, shot 2) with system/Project/task precedence and freeze the effective value in each request snapshot.
- [x] Compile controlled provider prompts from Chinese authority and exact references; preserve Chinese input/template/compiler links and never overwrite Chinese revisions.
- [x] Route user uploads and AI bytes through identical AssetStore finalize; edits create child assets/specs/attempts and leave parent hashes unchanged; retain mask lineage without canvas UI.
- [x] Mark exploratory outputs as ineligible for formal Timeline and require new formal Spec/Attempt when promoted.
- [x] Verify: `Push-Location app; mix test test/dramatizer/generation/openai_images_test.exs test/dramatizer/visuals/reference_workflow_test.exs; Pop-Location`.
- [x] Commit: `feat: add OpenAI image and reference production`.

### Task 10: Implement technical and multimodal semantic QC

**Requirements:** FR-060–FR-063, AT-005.

**Files:**

- Create: `app/lib/dramatizer/quality/{technical_qc,semantic_qc}.ex`
- Create: `app/lib/dramatizer/quality/jobs/{technical_qc_job,semantic_qc_job}.ex`
- Create: `app/priv/quality_schemas/image_semantic_qc.json`
- Test: `app/test/dramatizer/quality/technical_qc_test.exs`
- Test: `app/test/dramatizer/quality/semantic_qc_test.exs`

- [x] Test technical checks for decode, file integrity, format, exact/profile aspect tolerance, minimum dimensions, and hard selection block.
- [x] Test semantic evidence dimensions independently: identity/variant, wardrobe, location, light, prop, must/forbid, composition, camera, action, expression, style, artifact; each has status/confidence/reason/advice.
- [x] Build the semantic QC request from exact Spec/reference images and only direct selected neighbors; use OpenAI Responses multimodal `input_image` data URLs and strict structured output.
- [x] Test evaluator failed/unavailable and semantic fail/warning/inconclusive never hard-block technically valid selection; accepting a semantic fail may carry an optional note.
- [x] Trigger technical QC after finalize and semantic QC for every technically valid candidate without auto-selection or regeneration.
- [x] Verify: `Push-Location app; mix test test/dramatizer/quality; Pop-Location`.
- [x] Commit: `feat: add evidence based image quality checks`.

### Task 11: Implement dependency freshness, ChangeSet, and bounded recomputation

**Requirements:** FR-070–FR-074, AT-007, AT-009.

**Files:**

- Create: `app/priv/repo/migrations/*_create_change_tables.exs`
- Create: `app/lib/dramatizer/changes/{dependency_edge,change_set,change_node,impact}.ex`
- Create: `app/lib/dramatizer/changes.ex`
- Create: `app/lib/dramatizer/changes/jobs/change_node_job.ex`
- Test: `app/test/dramatizer/changes_test.exs`

**Public interfaces:**

```elixir
Changes.preview(project, old_revision, new_revision)
Changes.confirm(change_set, selected_targets)
Changes.resume(change_set)
Changes.resolve_stale(selection, :pin_old_input | {:replace, asset_id})
```

- [x] Test exact dependency traversal marks only affected specs/candidates/QC/selections and preserves historical decisions/assets.
- [x] Test preview has no side effects; confirmation freezes diff/graph epoch/actions; only deterministic recompile runs automatically; no Adapter call is enqueued.
- [x] Test unsubmitted old work is cancelled/superseded, submitted Attempts reconcile under old input and become stale, and old terminal results cannot overwrite newer work.
- [x] Test partial success/resume idempotency and no repeated successful calculation/cost.
- [x] Test changing a selected shot schedules debounced semantic QC for only that shot and direct neighbors.
- [x] Verify: `Push-Location app; mix test test/dramatizer/changes_test.exs; Pop-Location`.
- [x] Commit: `feat: propagate revision changes without hidden regeneration`.

### Task 12: Build Timeline, subtitles, motion, Preview, and formal FFmpeg export

**Requirements:** FR-080–FR-085, AT-008–AT-010 media behavior.

**Files:**

- Create: `app/priv/repo/migrations/*_create_timeline_tables.exs`
- Create: `app/lib/dramatizer/timeline/{timeline,clip,subtitle_cue,timeline_version,render_manifest}.ex`
- Create: `app/lib/dramatizer/timeline.ex`
- Create: `app/lib/dramatizer/timeline/{srt,render_recipe}.ex`
- Create: `app/lib/dramatizer/timeline/jobs/render_job.ex`
- Extend: `app/priv/media_worker/worker.py`
- Test: `app/test/dramatizer/timeline_test.exs`
- Test: `app/test/dramatizer/timeline/render_recipe_test.exs`
- Integration: `app/test/dramatizer/timeline/render_integration_test.exs`

- [x] Test Timeline Draft assembly in ShotPlan order, placeholder clips for missing images, reordering/replacing/adding/removing, duration snap/warning, static/push-in/pull-out/four pan presets, hard cut, and bounded cross-dissolve.
- [x] Generate sentence-level Chinese SubtitleCue drafts from exact Narrative dialogue events; editing text does not mutate Narrative; freeze exact text/timing/style/source in TimelineVersion.
- [x] Generate deterministic UTF-8 SRT and a canonical RenderInputManifest/recipe hash; unresolved stale blocks formal freeze/export but not preview, while explicit pin-old retains exact old closure.
- [x] Implement FFmpeg rendering: image loop/scale/crop and limited motion, transition timing, subtitle safe-area burn-in, H.264 yuv420p video, full-duration AAC stereo silence, faststart MP4, and SRT sidecar finalized as AssetVersions.
- [x] Preview derives profile resolution (default 540x960); formal derives frozen profile (default 1080x1920). Preview is cacheable and cannot be used as the formal asset.
- [x] Probe the output and assert decode, resolution, aspect, duration tolerance, H.264 video, AAC stereo audio, silence, and subtitle presence; finalize formal output then run export technical QC.
- [x] Verify: `Push-Location app; mix test test/dramatizer/timeline_test.exs test/dramatizer/timeline/render_recipe_test.exs test/dramatizer/timeline/render_integration_test.exs; Pop-Location`.
- [x] Commit: `feat: render subtitle animatics with silent audio`.

### Task 13: Deliver the guided LiveView project workspace

**Requirements:** Product experience section; all primary human gates.

**Files:**

- Modify: `app/lib/dramatizer_web/router.ex`
- Modify: `app/lib/dramatizer_web/components/layouts.ex`
- Modify: `app/lib/dramatizer_web/components/core_components.ex`
- Create: `app/lib/dramatizer_web/live/project_index_live.ex`
- Create: `app/lib/dramatizer_web/live/project_workspace_live.ex`
- Create: `app/lib/dramatizer_web/live/components/{stage_nav,run_panel,candidate_gallery,timeline_editor}.ex`
- Modify: `app/assets/css/app.css`
- Modify: `app/assets/js/app.js`
- Test: `app/test/dramatizer_web/live/project_index_live_test.exs`
- Test: `app/test/dramatizer_web/live/project_workspace_live_test.exs`

**Routes:**

```text
/                         Project list
/projects/:id/source      Source import and parser state
/projects/:id/analysis    Analysis DAG and repair/retry
/projects/:id/episodes    Candidate choice and Narrative confirmation
/projects/:id/visuals     Visual drafts and reference sets
/projects/:id/shots       Specs, candidates, QC, and selection
/projects/:id/timeline    Timeline, subtitles, preview, freeze/export
/projects/:id/runs        Runs, attempts, errors, costs, and resume
```

- [x] Write LiveView tests first for project create/open/archive and every stage route with empty/loading/failed/ready/waiting-user/stale states.
- [x] Implement direct-to-server LiveView uploads for `.txt,.md,.markdown,.pdf,.png,.jpg,.jpeg,.webp`; consume into Source/Asset commands rather than a UI-only path.
- [x] Implement all human gates: select episode, edit/confirm typed drafts, select reference/shot assets, confirm ChangeSet, resolve stale, edit/freeze Timeline, preview, and formal export.
- [x] Provide candidate comparison cards with Spec summary, reference thumbnails, per-dimension QC, cost/attempt trace, no default selection, and explicit user action.
- [x] Implement Chinese stage-oriented visual design with responsive 9:16 media panels, persistent project context, accessible labels/focus, and no login surface.
- [x] Verify: `Push-Location app; mix test test/dramatizer_web/live; mix assets.build; Pop-Location`.
- [x] Commit: `feat: add guided LiveView production workspace`.

### Task 14: Add backup/restore, consistency checks, and operational runbooks

**Requirements:** Section 8, AT-010.

**Files:**

- Create: `app/lib/mix/tasks/dramatizer.assets.verify.ex`
- Create: `app/lib/mix/tasks/dramatizer.backup.manifest.ex`
- Create: `scripts/backup.ps1`
- Create: `scripts/restore.ps1`
- Create: `scripts/dev.ps1`
- Create: `docs/runbooks/local-development.md`
- Create: `docs/runbooks/backup-restore.md`
- Test: `app/test/mix/tasks/dramatizer_assets_verify_test.exs`
- Integration: `app/test/dramatizer/backup_restore_test.exs`

- [x] Test manifest generation includes referenced asset ID/hash/relative path/size and effective non-secret config, detects missing/corrupt/orphan blobs, and never includes raw API keys.
- [x] Implement a write checkpoint, `pg_dump` through the scoped container, AssetStore copy plus manifest, and explicit resume; restore into a clean DB/asset root and verify hashes/references.
- [x] Reopen a restored fixture project and prove the same normalized RenderInputManifest/recipe hash can be regenerated.
- [x] Add `scripts/dev.ps1` to load root `.env`, start Compose, migrate, and run Phoenix bound to `127.0.0.1`; print only non-secret service URLs/status.
- [x] Verify: `Push-Location app; mix test test/mix/tasks/dramatizer_assets_verify_test.exs test/dramatizer/backup_restore_test.exs; Pop-Location`.
- [x] Commit: `feat: add local backup restore and consistency tools`.

### Task 15: Close all acceptance tests and browser E2E on Fake

**Requirements:** AT-001–AT-004, AT-006–AT-010 offline coverage.

**Files:**

- Create: `app/test/dramatizer/acceptance/*_test.exs`
- Create: `e2e/package.json`
- Create: `e2e/playwright.config.ts`
- Create: `e2e/tests/fake_animatic.spec.ts`
- Create: `e2e/fixtures/novel.md`
- Create: `scripts/e2e.ps1`
- Modify: `README.md`
- Modify: `STATUS.md`

- [x] Add named ExUnit acceptance tests mapping every offline AT and assert full lineage from TimelineClip back to source revisions.
- [x] Add a browser test that creates a Project, uploads the fixture, runs Fake analysis/production, confirms drafts, generates/selects candidates, edits Timeline/subtitles, previews, freezes, exports, opens run/cost trace, and downloads/locates MP4/SRT.
- [x] Inject one Fake node failure and a duplicate/out-of-order callback through test controls; resume in the browser and assert no duplicated candidate/cost.
- [x] Run FFprobe assertions on E2E MP4 and direct HTTP checks for all stage routes and finalized local asset serving.
- [x] Verify: `./scripts/test.ps1`; `./scripts/e2e.ps1`; `./docs/ai_short_drama_framework_v0.2/tools/validate_contracts.ps1`; `git diff --check`.
- [x] Commit: `test: prove fake MVP end to end`.

### Task 16: Run the real OpenAI text/image/QC smoke gate

**Requirements:** AT-005 and the real-provider MVP success criterion.

**Files:**

- Create: `scripts/real-smoke.ps1`
- Create: `app/test/dramatizer/acceptance/real_provider_smoke_test.exs`
- Modify: `docs/runbooks/local-development.md`
- Modify: `STATUS.md`

- [x] Gate: verify only whether `OPENAI_API_KEY` is available from process env or gitignored root `.env`. If absent, stop and ask the user to add it; never echo it.
- [x] Run one bounded Chinese fixture through `gpt-5.6-terra` whole-document structured extraction/candidate generation, generate the required references and at least two 3-shot candidates through `gpt-image-2`, run technical and `gpt-5.6-terra` semantic QC, select via explicit smoke fixture decision, and export the formal Animatic.
- [x] Assert request snapshots contain model/config/prompt/schema hashes but no raw key/auth header; capture provider request IDs, token/image usage and actual cost when returned.
- [x] Probe output media and trace every final clip through AssetVersion/QC/Attempt/RequestSnapshot/GenerationSpec/ShotPlan/Visual/Narrative/Source.
- [x] Keep generated real-provider fixtures/artifacts out of Git; write only redacted verification metadata to `STATUS.md`.
- [x] Verify: `./scripts/real-smoke.ps1` exits 0 and reports exact counts without secrets.
- [x] Commit: `test: verify real OpenAI production path`.

### Task 17: Final verification, self-review, publish, and run for user testing

**Requirements:** Complete PRD closure and runnable handoff.

**Files:**

- Modify: `STATUS.md`
- Modify: `README.md`
- Modify: this plan (all completed checkboxes)

- [ ] Re-read the confirmed PRD and record a FR-001–FR-092 / AT-001–AT-010 traceability table in `STATUS.md`; no requirement may be marked complete from test inference alone.
- [ ] Run fresh full gates: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`, `mix assets.build`, contract validator, Python tests/protocol probes, Playwright E2E, real-provider smoke, backup/restore, `git diff --check`, and a secret-pattern scan.
- [ ] Run a focused code review for data invariants, cross-context writes, terminal-state regression, duplicate external effects, error redaction, and subprocess cleanup; fix findings with regression tests.
- [ ] Commit all scoped changes, push `feat/dramatizer-mvp`, and verify the local branch equals `origin/feat/dramatizer-mvp`.
- [ ] Start `scripts/dev.ps1` as a hidden background process, wait for PostgreSQL/Phoenix/Oban health, probe `http://127.0.0.1:4000/`, and run one final browser navigation smoke against the persistent process.
- [ ] Record PID/log paths/URL and the exact fresh verification evidence in `STATUS.md`; leave the system running for user testing.
- [ ] Commit: `docs: record verified MVP handoff`; push and re-verify remote head.

## Scope Traceability

| PRD group | Implemented by |
|---|---|
| FR-001–FR-005 | Tasks 1–2, 13 |
| FR-010–FR-012 | Task 6 |
| FR-020–FR-022 | Task 7 |
| FR-030–FR-032 | Tasks 2, 8 |
| FR-040–FR-043 | Tasks 3, 8–9 |
| FR-050–FR-053 | Tasks 4–5, 7, 9 |
| FR-060–FR-063 | Tasks 5, 10 |
| FR-070–FR-074 | Task 11 |
| FR-080–FR-085 | Task 12 |
| FR-090–FR-092 | Tasks 1, 4, 14 |
| AT-001–AT-010 | Tasks 5–16 |

The plan is complete only when all task checkboxes are checked, every listed command has fresh passing output, the real-provider gate has run with the user's key, and the persistent localhost process has passed the final browser smoke.
