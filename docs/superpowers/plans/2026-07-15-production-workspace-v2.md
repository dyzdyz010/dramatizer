# Production Workspace v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the engineering-console UI with a real OpenAI-driven, domain-form production workspace that exposes every confirmed PRD concept without editable JSON.

**Architecture:** Keep the existing Phoenix modular monolith and immutable Revision/Attempt/Asset contracts. Add one reusable structured text-proposal runner, kind-specific draft form adapters, and focused LiveComponents for Narrative, VisualDesign, ShotPlan, settings, analysis review, and production review; the existing Context modules remain the only write boundary.

**Tech Stack:** Elixir/OTP, Phoenix LiveView, Ecto/PostgreSQL, Oban, OpenAI Responses and Images APIs, Tailwind CSS, Playwright, Python/FFmpeg worker.

## Global Constraints

- The product listens only on localhost and remains single-user with no auth, RBAC, RightsGate, content-safety, or security workflow.
- TXT, Markdown, and text-layer PDF are whole-document inputs; never chunk, truncate, or OCR.
- AI may create Draft/Proposal or Candidate assets only; only explicit user actions create immutable Revision or SelectionDecision records.
- Runtime configuration resolves `task override > Project override > system default` and freezes the effective values in ProviderRequestSnapshot.
- CorePrompt remains hidden and immutable; PromptAppendix is user-editable per task type.
- Normal user screens contain no editable JSON and no confirmed-payload JSON dump.
- Tests and ordinary E2E force Fake; the persistent acceptance service and forced real smoke use OpenAI.
- Use `mix.bat`, not `mix`, on Windows. Use `apply_patch` for repository edits.
- Every production behavior follows RED → verify expected failure → GREEN → focused regression → commit.
- Preserve user Project data and unrelated workspace files.

**Verified baseline:** `./scripts/test.ps1` completed before implementation with `100 passed, 1 excluded` in 242.5 seconds on branch `feat/dramatizer-mvp`.

---

### Task 1: Typed provider status, 项目预算, and project settings

**Files:**
- Create: `app/lib/dramatizer_web/forms/model_override_form.ex`
- Create: `app/lib/dramatizer_web/live/components/provider_status.ex`
- Create: `app/lib/dramatizer_web/live/components/project_settings.ex`
- Modify: `app/lib/dramatizer/projects.ex`
- Modify: `app/lib/dramatizer/costs.ex`
- Modify: `app/lib/dramatizer_web/live/project_workspace_live.ex`
- Modify: `app/config/config.exs`
- Test: `app/test/dramatizer_web/forms/model_override_form_test.exs`
- Test: `app/test/dramatizer_web/live/project_workspace_live_test.exs`
- Test: `app/test/dramatizer/costs_test.exs`

**Interfaces:**
- Produces: `DramatizerWeb.Forms.ModelOverrideForm.cast/2 :: {:ok, map()} | {:error, keyword()}`.
- Produces: `Projects.delete_model_override/2` for “restore inheritance”.
- Produces: `Costs.clear_budget_limit/1` so a blank limit restores the PRD's unlimited-but-recorded mode.
- Produces: `<ProviderStatus.provider_status mode credential_available model_summary>` and `<ProjectSettings.project_settings ...>`.

- [x] **Step 1: Write failing form and LiveView tests**

```elixir
test "image settings are cast from business controls without JSON" do
  assert {:ok, attrs} = ModelOverrideForm.cast(:shot_keyframe, %{
    "model" => "gpt-image-2", "quality" => "high",
    "size" => "768x1360", "candidate_count" => "3"
  })
  assert attrs.params == %{"quality" => "high", "size" => "768x1360", "candidate_count" => 3}
end

test "workspace identifies the active provider and exposes no JSON setting input", %{conn: conn, project: project} do
  {:ok, view, html} = live(conn, "/projects/#{project.id}/runs")
  assert html =~ "当前运行模式"
  refute html =~ "参数 JSON"
  refute has_element?(view, "textarea[name='model_override[params]']")
end
```

- [x] **Step 2: Run RED**

Run: `cd app; mix.bat test test/dramatizer_web/forms/model_override_form_test.exs test/dramatizer_web/live/project_workspace_live_test.exs`

Expected: form module missing and old JSON textarea assertion fails.

- [x] **Step 3: Implement typed casting and status/settings components**

Text tasks accept `model` and `reasoning_effort`; image tasks accept `model`, `quality`, `size`, and positive `candidate_count`. Render effective system and Project values, credential reference availability, PromptAppendix revisions, profile units, and “restore inheritance”. Remove settings markup from the runs stage and render it in a settings drawer controlled by `open-settings`/`close-settings` events.

- [x] **Step 4: Run GREEN and regressions**

Run: `cd app; mix.bat test test/dramatizer_web/forms/model_override_form_test.exs test/dramatizer_web/live/project_workspace_live_test.exs test/dramatizer/projects_test.exs test/dramatizer/costs_test.exs test/dramatizer/generation/config_resolver_test.exs`

Expected: all selected tests pass and no user-facing model JSON field exists.

- [x] **Step 5: Commit**

```powershell
git add app/config/config.exs app/lib/dramatizer/projects.ex app/lib/dramatizer/costs.ex app/lib/dramatizer_web/forms app/lib/dramatizer_web/live/components/provider_status.ex app/lib/dramatizer_web/live/components/project_settings.ex app/lib/dramatizer_web/live/project_workspace_live.ex app/test/dramatizer_web app/test/dramatizer/costs_test.exs
git commit -m "feat: add typed provider settings"
```

### Task 2: Reusable structured text Proposal runtime

**Files:**
- Create: `app/lib/dramatizer/generation/structured_text_proposal.ex`
- Create: `app/lib/dramatizer/generation/proposal_schemas.ex`
- Create: `app/priv/proposal_schemas/narrative_proposal.json`
- Create: `app/priv/proposal_schemas/visual_design_proposal.json`
- Create: `app/priv/proposal_schemas/directing_proposal.json`
- Create: `app/priv/prompts/v1/narrative_proposal.md`
- Create: `app/priv/prompts/v1/visual_design_proposal.md`
- Modify: `app/lib/dramatizer/prompts/catalog.ex`
- Modify: `app/config/config.exs`
- Test: `app/test/dramatizer/generation/structured_text_proposal_test.exs`
- Test: `app/test/dramatizer/prompts/composer_test.exs`

**Interfaces:**
- Produces: `StructuredTextProposal.propose(project, task_type, authority, opts \\ [])` for `:narrative_proposal | :visual_design_proposal | :directing_proposal`.
- Returns: `{:ok, %{output: map(), request_snapshot: ProviderRequestSnapshot.t(), attempt: Attempt.t()}}`.
- Reuses: `Generation.create_spec/2`, `Generation.prepare_attempt/4`, Costs reserve/settle, OpenAIResponses, CorePrompt/PromptAppendix.

- [x] **Step 1: Write failing persistence, Fake, OpenAI-submitter, and invalid-output tests**

```elixir
test "fake narrative proposal persists the same request and attempt contract", %{project: project} do
  assert {:ok, result} = StructuredTextProposal.propose(project, :narrative_proposal, authority(), provider_mode: :fake)
  assert result.output["schema_version"] == "narrative-draft-v2"
  assert result.request_snapshot.task_type == "narrative_proposal"
  assert result.attempt.status == :succeeded
end

test "invalid structured output fails the attempt instead of guessing fields", %{project: project} do
  submitter = fn _, _ -> {:ok, %{output: %{"bad" => true}, usage: %{}, request_id: "req_bad"}} end
  assert {:error, :invalid_proposal_output} = StructuredTextProposal.propose(project, :visual_design_proposal, authority(), provider_mode: :openai, submitter: submitter)
  assert Repo.one!(Attempt).status == :failed
end
```

- [x] **Step 2: Run RED**

Run: `cd app; mix.bat test test/dramatizer/generation/structured_text_proposal_test.exs test/dramatizer/prompts/composer_test.exs`

Expected: new modules, schemas, and prompt tasks are absent.

- [x] **Step 3: Implement the runner and strict schemas**

The runner composes the task prompt from canonical Chinese authority, prepares a non-formal `text_proposal` GenerationSpec, freezes schema/prompt/config hashes, reserves cost for OpenAI, validates returned output with the selected JSON Schema, records usage/request IDs, and reuses a succeeded Attempt for identical input. Fake output must contain rich Scene/Beat/Event, VisualVariant, and Shot fields sufficient for the browser E2E.

- [x] **Step 4: Run GREEN and adapter regressions**

Run: `cd app; mix.bat test test/dramatizer/generation/structured_text_proposal_test.exs test/dramatizer/generation/openai_responses_test.exs test/dramatizer/generation/image_prompt_proposal_test.exs test/dramatizer/prompts/composer_test.exs`

Expected: all selected tests pass; invalid fields are rejected, not removed.

- [x] **Step 5: Commit**

```powershell
git add app/config/config.exs app/lib/dramatizer/generation app/lib/dramatizer/prompts app/priv/proposal_schemas app/priv/prompts app/test/dramatizer/generation app/test/dramatizer/prompts
git commit -m "feat: add structured production proposals"
```

### Task 3: Versioned Draft form adapters

**Files:**
- Create: `app/lib/dramatizer_web/forms/narrative_draft_form.ex`
- Create: `app/lib/dramatizer_web/forms/visual_design_draft_form.ex`
- Create: `app/lib/dramatizer_web/forms/shot_plan_draft_form.ex`
- Create: `app/lib/dramatizer_web/forms/form_support.ex`
- Modify: `app/lib/dramatizer/revisions.ex`
- Modify: `app/lib/dramatizer/visuals.ex`
- Modify: `app/lib/dramatizer/directing.ex`
- Test: `app/test/dramatizer_web/forms/draft_forms_test.exs`
- Test: `app/test/dramatizer/revisions_test.exs`
- Test: `app/test/dramatizer/visuals_test.exs`

**Interfaces:**
- `NarrativeDraftForm`, `VisualDesignDraftForm`, and `ShotPlanDraftForm` each produce `from_payload/1`, `cast/2`, `add/3`, `remove/3`, and `move/4`.
- `cast/2` preserves unknown legacy payload keys while replacing owned fields.
- `Revisions.replace_draft_payload/2` replaces a validated complete payload under optimistic lock; `update_draft/2` remains merge-oriented for compatibility.

- [x] **Step 1: Write failing round-trip and validation tests**

```elixir
test "narrative form round-trips nested business fields and preserves legacy extensions" do
  current = %{"legacy_extension" => %{"keep" => true}, "scenes" => []}
  params = %{"episode" => %{"title" => "雨夜来信"}, "scenes" => %{"0" => %{"id" => "SC001", "title" => "车站", "summary" => "收到信"}}}
  assert {:ok, payload} = NarrativeDraftForm.cast(params, current)
  assert payload["schema_version"] == "narrative-draft-v2"
  assert hd(payload["scenes"])["title"] == "车站"
  assert payload["legacy_extension"] == %{"keep" => true}
end

test "shot form rejects inverted duration bounds" do
  assert {:error, errors} = ShotPlanDraftForm.cast(%{"shots" => %{"0" => shot_params("3000", "2000", "1000")}}, %{})
  assert errors[:shots]
end
```

- [x] **Step 2: Run RED**

Run: `cd app; mix.bat test test/dramatizer_web/forms/draft_forms_test.exs test/dramatizer/revisions_test.exs test/dramatizer/visuals_test.exs`

Expected: adapters and replace command are missing.

- [x] **Step 3: Implement deterministic casts and nested operations**

Normalize indexed maps in numeric order; generate stable IDs only for genuinely new items; parse checkbox, integer, decimal, comma/newline tag lists, source semantics, and ProductionProfile overrides. Validate unique IDs, required references, source locator requirements, VisualVariant/slot completeness, shot duration ordering, and must-show/must-not-show conflicts.

- [x] **Step 4: Run GREEN and compiler/timeline regressions**

Run: `cd app; mix.bat test test/dramatizer_web/forms/draft_forms_test.exs test/dramatizer/revisions_test.exs test/dramatizer/visuals_test.exs test/dramatizer/directing/compiler_test.exs test/dramatizer/timeline_test.exs`

Expected: all selected tests pass and legacy payload extensions survive form save/confirm.

- [x] **Step 5: Commit**

```powershell
git add app/lib/dramatizer/revisions.ex app/lib/dramatizer/visuals.ex app/lib/dramatizer/directing.ex app/lib/dramatizer_web/forms app/test/dramatizer_web/forms app/test/dramatizer/revisions_test.exs app/test/dramatizer/visuals_test.exs
git commit -m "feat: add versioned authority forms"
```

### Task 4: 自动整本分析 and Narrative production form

**Files:**
- Create: `app/lib/dramatizer_web/live/components/analysis_review.ex`
- Create: `app/lib/dramatizer_web/live/components/narrative_editor.ex`
- Modify: `app/lib/dramatizer/narrative.ex`
- Modify: `app/lib/dramatizer_web/live/project_workspace_live.ex`
- Test: `app/test/dramatizer/narrative_test.exs`
- Test: `app/test/dramatizer_web/live/project_workspace_live_test.exs`

**Interfaces:**
- Produces: `Narrative.create_proposal_draft(project, snapshot, candidate_id, proposal_output)`.
- Import success calls the existing persisted DAG/Runner and navigates to `/analysis`.
- Candidate selection calls StructuredTextProposal and then creates one Narrative Draft.

- [x] **Step 1: Write failing automatic-flow and no-JSON tests**

```elixir
test "upload automatically analyzes and selecting a candidate creates a rich form draft", %{conn: conn, project: project} do
  {:ok, source, _} = live(conn, "/projects/#{project.id}/source")
  upload_text(source, "story.txt", "雨夜里，林夏在车站收到匿名信。")
  assert Repo.get_by!(AnalysisSnapshot, project_id: project.id)
  {:ok, episodes, html} = live(conn, "/projects/#{project.id}/episodes")
  episodes |> element("button[phx-click='select-episode']") |> render_click()
  assert html = render(episodes)
  assert html =~ "分集概览"
  assert html =~ "Scene"
  refute html =~ "结构化内容"
  refute html =~ "{\""
end
```

- [x] **Step 2: Run RED**

Run: `cd app; mix.bat test test/dramatizer/narrative_test.exs test/dramatizer_web/live/project_workspace_live_test.exs`

Expected: upload does not auto-analyze and the old JSON editor is rendered.

- [x] **Step 3: Implement analysis review and Narrative editor**

Render people/relations, places/props/world, events/timeline, merge, candidates, and conflicts as business cards with provenance chips and source-locator Inspector. NarrativeEditor renders episode, Profile override, Scene, Beat, StoryEvent, DialogueEvent, dependencies, conflict items, add/remove/reorder controls, autosave status, and confirm/derive actions.

- [x] **Step 4: Run GREEN and source-analysis regressions**

Run: `cd app; mix.bat test test/dramatizer/narrative_test.exs test/dramatizer_web/live/project_workspace_live_test.exs test/dramatizer/acceptance/source_analysis_test.exs`

Expected: all pass and source import creates or reuses one AnalysisSnapshot for the exact revision set.

- [x] **Step 5: Commit**

```powershell
git add app/lib/dramatizer/narrative.ex app/lib/dramatizer_web/live/components/analysis_review.ex app/lib/dramatizer_web/live/components/narrative_editor.ex app/lib/dramatizer_web/live/project_workspace_live.ex app/test/dramatizer/narrative_test.exs app/test/dramatizer_web/live/project_workspace_live_test.exs
git commit -m "feat: build narrative production workspace"
```

### Task 5: VisualDesign Proposal, object/Variant form, and reference matrix

**Files:**
- Create: `app/lib/dramatizer_web/live/components/visual_design_editor.ex`
- Create: `app/lib/dramatizer_web/live/components/reference_matrix.ex`
- Modify: `app/lib/dramatizer/visuals.ex`
- Modify: `app/lib/dramatizer_web/live/project_workspace_live.ex`
- Modify: `app/lib/dramatizer_web/live/components/candidate_gallery.ex`
- Test: `app/test/dramatizer/visuals_test.exs`
- Test: `app/test/dramatizer_web/live/project_workspace_live_test.exs`

**Interfaces:**
- Confirming Narrative auto-creates one VisualDesign Proposal Draft.
- VisualDesignEditor owns objects, type-specific fields, importance/reference flags, VisualVariants, constraints, and editable reference slots.
- ReferenceMatrix groups candidates and primary selections by object/Variant/slot.

- [x] **Step 1: Write failing visual-proposal and form tests**

```elixir
test "confirming narrative produces a visual proposal with editable Variant cards", %{conn: conn, project: project} do
  narrative = confirmed_narrative(project)
  {:ok, visuals, html} = live(conn, "/projects/#{project.id}/visuals")
  assert html =~ "角色"
  assert html =~ "场景"
  assert html =~ "道具"
  assert html =~ "视觉 Variant"
  refute html =~ "角色／场景／道具对象 JSON"
end

test "explicit reference_required survives normalization" do
  assert {:ok, draft} = Visuals.create_design_draft(project, narrative, [%{"id" => "prop:key", "type" => "prop", "name" => "钥匙", "reference_required" => true, "variants" => [%{"id" => "intact"}]}])
  assert hd(draft.payload["objects"])["reference_required"]
end
```

- [x] **Step 2: Run RED**

Run: `cd app; mix.bat test test/dramatizer/visuals_test.exs test/dramatizer_web/live/project_workspace_live_test.exs`

Expected: explicit reference flag is overwritten and the JSON visual form still appears.

- [x] **Step 3: Implement visual proposal and production matrix**

Use StructuredTextProposal with confirmed Narrative authority. Render character/location/prop tabs, common and type-specific fields, provenance, VisualVariant cards, editable slot templates, exploration labels, upload, generate, compare, select, edit-child, and ReferenceSet confirmation readiness.

- [x] **Step 4: Run GREEN and reference workflow regressions**

Run: `cd app; mix.bat test test/dramatizer/visuals_test.exs test/dramatizer/visuals/reference_workflow_test.exs test/dramatizer_web/live/project_workspace_live_test.exs test/dramatizer/acceptance/assets_changes_test.exs`

Expected: all selected tests pass and formal selections still require confirmed VisualDesign.

- [x] **Step 5: Commit**

```powershell
git add app/lib/dramatizer/visuals.ex app/lib/dramatizer_web/live/components/visual_design_editor.ex app/lib/dramatizer_web/live/components/reference_matrix.ex app/lib/dramatizer_web/live/components/candidate_gallery.ex app/lib/dramatizer_web/live/project_workspace_live.ex app/test/dramatizer/visuals_test.exs app/test/dramatizer_web/live/project_workspace_live_test.exs
git commit -m "feat: build visual authority workspace"
```

### Task 6: Directing Proposal, full Shot form, continuity, and Spec review

**Files:**
- Create: `app/lib/dramatizer_web/live/components/shot_plan_editor.ex`
- Create: `app/lib/dramatizer_web/live/components/generation_spec_review.ex`
- Modify: `app/lib/dramatizer/directing.ex`
- Modify: `app/lib/dramatizer/directing/compiler.ex`
- Modify: `app/priv/generation_templates/v1/shot_keyframe.json.eex`
- Modify: `app/lib/dramatizer_web/live/project_workspace_live.ex`
- Test: `app/test/dramatizer/directing/compiler_test.exs`
- Test: `app/test/dramatizer_web/forms/draft_forms_test.exs`
- Test: `app/test/dramatizer_web/live/project_workspace_live_test.exs`

**Interfaces:**
- Confirming ReferenceSet auto-creates one Directing Proposal Draft.
- ShotPlanEditor owns Scene groups and nested Shot presentation, coverage, duration, camera, staging, sound, continuity, and constraints.
- Compiler accepts `shot-plan-draft-v2` while retaining legacy v1 compatibility.

- [x] **Step 1: Write failing rich-shot compile and UI tests**

```elixir
test "compiler preserves rich Chinese authority in deterministic spec" do
  shot = rich_shot(%{"camera" => %{"movement" => "push_in", "shot_size" => "近景"}, "constraints" => %{"must_show" => ["匿名信"], "must_not_show" => ["第三人"]}})
  assert {:ok, first} = Compiler.compile(project, confirmed_inputs(project, shot))
  assert {:ok, second} = Compiler.compile(project, confirmed_inputs(project, shot))
  assert first.hash == second.hash
  spec = hd(first.payload["specs"])["payload"]
  assert spec["camera"] == "push_in"
  assert spec["must_show"] == ["匿名信"]
end

test "shot workspace renders domain controls and no ShotPlan JSON", %{conn: conn, project: project} do
  prepare_confirmed_reference_set(project)
  {:ok, shots, html} = live(conn, "/projects/#{project.id}/shots")
  assert html =~ "呈现目标"
  assert html =~ "连续性"
  refute html =~ "ShotPlan JSON"
end
```

- [x] **Step 2: Run RED**

Run: `cd app; mix.bat test test/dramatizer/directing/compiler_test.exs test/dramatizer_web/forms/draft_forms_test.exs test/dramatizer_web/live/project_workspace_live_test.exs`

Expected: nested camera/constraints are not compiled and the JSON form remains.

- [x] **Step 3: Implement directing form, continuity strip, and Spec cards**

Render compact/common Shot controls with expandable full director parameters. Normalize nested camera movement for the existing Timeline motion mapping while keeping the full Chinese authority in the Spec. SpecReview shows formal/exploration, exact revisions, constraints, model media profile, compiler/template versions, hash, shot selection controls, candidate count, and explicit paid-generation action.

- [x] **Step 4: Run GREEN and directing/generation regressions**

Run: `cd app; mix.bat test test/dramatizer/directing/compiler_test.exs test/dramatizer/generation/orchestrator_invariants_test.exs test/dramatizer/timeline_test.exs test/dramatizer_web/live/project_workspace_live_test.exs`

Expected: all pass with deterministic v1 and v2 compilation.

- [x] **Step 5: Commit**

```powershell
git add app/lib/dramatizer/directing.ex app/lib/dramatizer/directing/compiler.ex app/priv/generation_templates/v1/shot_keyframe.json.eex app/lib/dramatizer_web/live/components/shot_plan_editor.ex app/lib/dramatizer_web/live/components/generation_spec_review.ex app/lib/dramatizer_web/live/project_workspace_live.ex app/test/dramatizer/directing/compiler_test.exs app/test/dramatizer_web
git commit -m "feat: build directing production workspace"
```

### Task 7: Candidate review, ChangeSet/stale, Timeline, and run center productization

**Files:**
- Modify: `app/lib/dramatizer_web/live/components/candidate_gallery.ex`
- Create: `app/lib/dramatizer_web/live/components/change_impact.ex`
- Modify: `app/lib/dramatizer_web/live/components/timeline_editor.ex`
- Modify: `app/lib/dramatizer_web/live/components/run_panel.ex`
- Modify: `app/lib/dramatizer_web/live/project_workspace_live.ex`
- Test: `app/test/dramatizer_web/live/project_workspace_live_test.exs`
- Test: `app/test/dramatizer/changes_test.exs`
- Test: `app/test/dramatizer/timeline_test.exs`

**Interfaces:**
- CandidateGallery groups by slot/shot, exposes reference thumbnails, all semantic dimensions, optional acceptance note, and explicit select/regenerate/edit/upstream actions.
- ChangeImpact renders exact affected objects and selectable range; no JSON diff.
- TimelineEditor renders storyboards/tracks and keeps the existing Context commands.

- [x] **Step 1: Write failing UI contract tests**

```elixir
test "candidate review exposes four explicit actions and dimension evidence", %{conn: conn, project: project} do
  seed_candidate_with_qc(project)
  {:ok, view, html} = live(conn, "/projects/#{project.id}/shots")
  assert html =~ "选择为主图"
  assert html =~ "再次生成"
  assert html =~ "基于此图编辑"
  assert html =~ "返回上游修改"
  assert html =~ "角色身份与 Variant"
end

test "timeline labels the silence track and separates preview from formal export", %{conn: conn, project: project} do
  seed_timeline(project)
  {:ok, view, html} = live(conn, "/projects/#{project.id}/timeline")
  assert html =~ "AAC 双声道静音占位"
  assert has_element?(view, "[data-render-path='preview']")
  assert has_element?(view, "[data-render-path='formal']")
end
```

- [x] **Step 2: Run RED**

Run: `cd app; mix.bat test test/dramatizer_web/live/project_workspace_live_test.exs test/dramatizer/changes_test.exs test/dramatizer/timeline_test.exs`

Expected: product labels, grouped evidence, and dual render-path elements are absent.

- [x] **Step 3: Implement review and recovery surfaces**

Keep all existing business commands, but replace raw IDs and generic rows with business summaries, exact-state chips, persistent error/recovery cards, stale resolution choices, ChangeSet tree/range controls, storyboard clips, duration-range markers, motion/transition Inspector, subtitle authority warning, preview player/downloads, and formal checklist.

- [x] **Step 4: Run GREEN and acceptance regressions**

Run: `cd app; mix.bat test test/dramatizer_web/live/project_workspace_live_test.exs test/dramatizer/changes_test.exs test/dramatizer/timeline_test.exs test/dramatizer/acceptance/timeline_restore_test.exs`

Expected: all selected tests pass and unresolved stale still blocks formal only.

- [x] **Step 5: Commit**

```powershell
git add app/lib/dramatizer_web/live/components app/lib/dramatizer_web/live/project_workspace_live.ex app/test/dramatizer_web/live/project_workspace_live_test.exs
git commit -m "feat: productize review and timeline flows"
```

### Task 8: Workspace shell, compact visual system, responsiveness, and accessibility

**Files:**
- Modify: `app/lib/dramatizer_web/components/layouts.ex`
- Modify: `app/lib/dramatizer_web/live/components/stage_nav.ex`
- Modify: `app/lib/dramatizer_web/live/project_index_live.ex`
- Modify: `app/lib/dramatizer_web/live/project_workspace_live.ex`
- Modify: `app/assets/css/app.css`
- Modify: `app/assets/js/app.js`
- Test: `app/test/dramatizer_web/live/project_index_live_test.exs`
- Test: `app/test/dramatizer_web/live/project_workspace_live_test.exs`

**Interfaces:**
- Desktop shell: top status bar, left stage rail, main canvas, optional right Inspector, sticky next-action bar.
- JS hooks are limited to Inspector state, autosave debounce, and keyboard-accessible reordering; domain writes remain LiveView events.

- [x] **Step 1: Write failing structural/accessibility tests**

```elixir
test "workspace uses a stage rail, provider header, main canvas, inspector, and next action", %{conn: conn, project: project} do
  {:ok, view, _} = live(conn, "/projects/#{project.id}/source")
  assert has_element?(view, "aside[aria-label='制作阶段']")
  assert has_element?(view, "header [data-provider-mode]")
  assert has_element?(view, "main[data-workspace-canvas]")
  assert has_element?(view, "[data-next-action]")
end
```

- [x] **Step 2: Run RED**

Run: `cd app; mix.bat test test/dramatizer_web/live/project_index_live_test.exs test/dramatizer_web/live/project_workspace_live_test.exs`

Expected: the old horizontal nav and page structure fail the new selectors.

- [x] **Step 3: Implement the visual system**

Reduce display headings, use the warm-neutral/ink/orange/teal token set, add compact form grids, Authority/Draft/Candidate/Run/Alert card variants, responsive rail/Inspector behavior, visible focus, non-color status labels, keyboard reorder alternatives, loading-disabled buttons, and mobile single-column layouts. Remove the persistent state legend and development controls from OpenAI mode.

- [x] **Step 4: Build assets and run UI tests**

Run: `cd app; mix.bat format --check-formatted; mix.bat compile --warnings-as-errors; mix.bat assets.build; mix.bat test test/dramatizer_web/live/project_index_live_test.exs test/dramatizer_web/live/project_workspace_live_test.exs`

Expected: format, compile, assets, and UI tests all pass without warnings.

- [x] **Step 5: Commit**

```powershell
git add app/lib/dramatizer_web app/assets app/test/dramatizer_web
git commit -m "feat: redesign the production workspace"
```

### Task 9: Browser E2E, real OpenAI smoke, compatibility, and handoff

**Files:**
- Modify: `e2e/tests/fake_animatic.spec.ts`
- Modify: `app/test/dramatizer/acceptance/real_provider_smoke_test.exs`
- Modify: `scripts/dev.ps1`
- Modify: `.env.example`
- Modify: `README.md`
- Modify: `STATUS.md`
- Modify: `docs/runbooks/local-development.md`

**Interfaces:**
- Fake E2E completes the full form workflow without JSON or paid calls.
- Forced real smoke creates a fresh Project and exercises analysis plus all three text Proposal tasks, image prompt generation, Images, QC, Timeline, and formal export.
- Persistent dev launch reports provider mode and refuses silent Fake fallback when OpenAI is explicitly configured.

- [ ] **Step 1: Update E2E and real-smoke assertions before compatibility fixes**

```typescript
await expect(page.getByText('OpenAI 已启用').or(page.getByText('Fake 模拟模式'))).toBeVisible();
await expect(page.locator('textarea').filter({ hasText: /\{|\[/ })).toHaveCount(0);
await expect(page.getByRole('heading', { name: '分集概览' })).toBeVisible();
await expect(page.getByText('视觉 Variant')).toBeVisible();
await expect(page.getByText('连续性')).toBeVisible();
```

The real-provider acceptance test asserts persisted RequestSnapshots for `narrative_proposal`, `visual_design_proposal`, and `directing_proposal` in addition to the existing 33-call chain.

- [ ] **Step 2: Run RED on browser and real-smoke selection**

Run: `./scripts/e2e.ps1`

Expected: old selectors/workflow fail until the new E2E is aligned with the completed form flow. Do not run paid real smoke until all local gates are green.

- [ ] **Step 3: Fix compatibility and documentation**

Ensure legacy current Project Drafts render through adapters without data loss, update scripts and docs with explicit provider behavior, and record the new UI/Proposal evidence in STATUS. Set the gitignored root `.env` to `DRAMATIZER_PROVIDER=openai` without printing the key.

- [ ] **Step 4: Run complete fresh verification**

Run in order:

```powershell
cd app
mix.bat format --check-formatted
mix.bat compile --warnings-as-errors
mix.bat assets.build
cd ..
./scripts/test.ps1
./docs/ai_short_drama_framework_v0.2/tools/validate_contracts.ps1
./scripts/e2e.ps1
./scripts/real-smoke.ps1 -Force
```

Expected: format/compile/assets exit 0; ExUnit reports zero failures with only the explicit real-provider exclusion in the ordinary suite; contract validator passes all schemas/examples/negative cases/links; Playwright completes the form-driven Fake workflow; forced OpenAI smoke completes all Proposal, image, QC, Timeline, and formal export assertions.

- [ ] **Step 5: Restart persistent service and browser-smoke user data path**

Stop only the PIDs recorded for the existing Dramatizer supervisor/server, restart `scripts/dev.ps1` with the root `.env`, verify HTTP 200 and an OpenAI provider chip, upload a fresh Unicode text PDF through the browser, and confirm it reaches an AnalysisSnapshot without deleting the user's `test` Project.

- [ ] **Step 6: Secret/diff/publish gate and commit**

```powershell
git diff --check
git status --short
git add e2e/tests/fake_animatic.spec.ts app/test/dramatizer/acceptance/real_provider_smoke_test.exs scripts/dev.ps1 .env.example README.md STATUS.md docs/runbooks/local-development.md
git commit -m "test: verify production workspace end to end"
git push origin feat/dramatizer-mvp
```

Verify local HEAD equals `git ls-remote origin refs/heads/feat/dramatizer-mvp`. The raw API key must have zero tracked-file matches; `.env`, generated assets, logs, screenshots, and smoke databases remain ignored.
