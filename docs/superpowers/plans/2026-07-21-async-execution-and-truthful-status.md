# Async Execution and Truthful Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every Provider, QC, and media operation out of LiveView into durable Oban-backed workflows whose state is recovered from PostgreSQL and refreshed through PubSub.

**Architecture:** Existing `WorkflowRun` and `NodeRun` records become the durable execution envelope for analysis, proposals, image generation, QC, and rendering. Ecto.Multi atomically persists facts and Oban jobs, workers update domain records through a shared lifecycle, and project-scoped PubSub messages invalidate narrowly loaded LiveView state.

**Tech Stack:** Elixir, Phoenix LiveView 1.1, Ecto SQL 3.14, PostgreSQL, Oban 2.23, ExUnit, Playwright.

## Global Constraints

- Keep the product single-user, localhost, and local-first; do not add auth, RBAC, tenant isolation, or RightsGate.
- Fake and real Providers use the same execution path; only the adapter changes.
- Database records are the fact source; PubSub is an invalidation signal only.
- Oban arguments contain database IDs and stable scalar values only.
- Ordinary tests always use Fake Provider; real Provider smoke requires `DRAMATIZER_REAL_SMOKE=1`.
- Preserve the existing GenerationSpec, Revision, Asset, Selection, Timeline, and cost semantics.
- Use test-first red-green-refactor for every production behavior change.

---

## File Responsibility Map

- `app/lib/dramatizer/execution/notifier.ex`: project topic and loss-tolerant invalidation events.
- `app/lib/dramatizer/execution/job_result.ex`: stable classification of retryable, permanent, unknown-remote, and cancelled results.
- `app/lib/dramatizer/execution/worker_lifecycle.ex`: NodeRun ownership, lease, retry, terminal transition, and notification orchestration.
- `app/lib/dramatizer/execution/reconciler_job.ex`: repair orphaned running NodeRuns after abnormal worker termination.
- `app/lib/dramatizer/workflow/enqueue.ex`: atomic WorkflowRun, NodeRun, and Oban Job creation.
- `app/lib/dramatizer/generation/pipeline.ex`: proposal/image/QC DAG definition and node execution dispatch.
- `app/lib/dramatizer/generation/jobs/generation_node_job.ex`: Oban adapter for generation pipeline NodeRuns.
- `app/lib/dramatizer_web/project_workspace/subscription.ex`: project subscription and resource-to-slice mapping.
- Existing contexts retain domain behavior; LiveView calls enqueue APIs and never invokes remote work.

### Task 1: Stabilize the Existing AT-004 Acceptance Assertion

**Files:**
- Modify: `app/test/dramatizer/acceptance/source_analysis_test.exs:67`

**Interfaces:**
- Consumes: `NodeRun.result["provider_request_snapshot_ids"]`, the ordered IDs already persisted by analysis repair.
- Produces: deterministic validation-error assertions independent of PostgreSQL tie ordering.

- [ ] **Step 1: Make the regression deterministic and prove the old query is ambiguous**

Replace the global Attempt query with the persisted request order:

```elixir
errors =
  succeeded.result["provider_request_snapshot_ids"]
  |> Enum.map(fn snapshot_id ->
    Repo.get_by!(Attempt, provider_request_snapshot_id: snapshot_id, attempt_number: 1)
  end)
  |> Enum.map(&get_in(&1.response_metadata, ["validation_errors"]))
```

- [ ] **Step 2: Run the focused test repeatedly**

Run: `1..10 | ForEach-Object { mix.bat test test/dramatizer/acceptance/source_analysis_test.exs:67 --seed $_ }`

Expected: all ten runs report `1 test, 0 failures`.

- [ ] **Step 3: Commit**

```powershell
git add app/test/dramatizer/acceptance/source_analysis_test.exs
git commit -m "test: stabilize analysis repair ordering"
```

### Task 2: Add Execution Notifications and Error Classification

**Files:**
- Create: `app/lib/dramatizer/execution/notifier.ex`
- Create: `app/lib/dramatizer/execution/job_result.ex`
- Create: `app/test/dramatizer/execution/notifier_test.exs`
- Create: `app/test/dramatizer/execution/job_result_test.exs`

**Interfaces:**
- Produces: `Notifier.topic/1`, `Notifier.subscribe/1`, `Notifier.broadcast/4`, and `JobResult.classify/1`.
- Consumed by: every worker lifecycle and the LiveView subscription adapter.

- [ ] **Step 1: Write failing notification tests**

```elixir
test "broadcast carries ids only" do
  project_id = Ecto.UUID.generate()
  resource_id = Ecto.UUID.generate()
  assert :ok = Notifier.subscribe(project_id)
  assert :ok = Notifier.broadcast(project_id, :generation, resource_id, :queued)
  assert_receive {:execution_changed, %{project_id: ^project_id, resource: :generation,
                                         resource_id: ^resource_id, event: :queued}}
end
```

- [ ] **Step 2: Write failing classification tests**

```elixir
assert JobResult.classify(:provider_timeout) == {:retryable, "provider_timeout"}
assert JobResult.classify({:http_status, 429}) == {:retryable, "provider_rate_limited"}
assert JobResult.classify(:invalid_proposal_output) == {:permanent, "invalid_proposal_output"}
assert JobResult.classify(:unknown_remote_state) == {:unknown_remote, "unknown_remote_state"}
assert JobResult.classify(:cancelled) == {:cancelled, "cancelled"}
```

- [ ] **Step 3: Run tests and confirm undefined-module failures**

Run: `mix.bat test test/dramatizer/execution/notifier_test.exs test/dramatizer/execution/job_result_test.exs`

Expected: compilation fails because `Dramatizer.Execution.Notifier` and `JobResult` do not exist.

- [ ] **Step 4: Implement the two focused modules**

`Notifier` uses topic `project:<project_id>:execution` and calls `Phoenix.PubSub`. `JobResult` uses explicit clauses for timeouts, 429, 5xx, validation, cancellation, and unknown remote state; unmatched values are permanent with a redacted `inspect/1` code capped at 200 bytes.

- [ ] **Step 5: Run focused tests and commit**

Run: `mix.bat test test/dramatizer/execution/notifier_test.exs test/dramatizer/execution/job_result_test.exs`

Expected: `0 failures`.

```powershell
git add app/lib/dramatizer/execution app/test/dramatizer/execution
git commit -m "feat: add execution events and error classes"
```

### Task 3: Add NodeRun Job Ownership, Leases, and Reconciliation

**Files:**
- Create: `app/priv/repo/migrations/20260721090000_add_execution_fields_to_node_runs.exs`
- Modify: `app/lib/dramatizer/workflow/node_run.ex`
- Modify: `app/lib/dramatizer/workflow.ex`
- Create: `app/lib/dramatizer/execution/worker_lifecycle.ex`
- Create: `app/lib/dramatizer/execution/reconciler_job.ex`
- Create: `app/lib/mix/tasks/dramatizer.execution.reconcile.ex`
- Modify: `app/config/config.exs`
- Create: `app/test/dramatizer/execution/worker_lifecycle_test.exs`
- Create: `app/test/dramatizer/execution/reconciler_job_test.exs`

**Interfaces:**
- Produces: `WorkerLifecycle.start/2`, `succeed/3`, `fail/3`; `ReconcilerJob.perform/1`; `mix dramatizer.execution.reconcile`.
- NodeRun fields: `worker :string`, `active_job_id :integer`, `lease_expires_at :utc_datetime_usec`, `next_retry_at :utc_datetime_usec`.

- [ ] **Step 1: Write failing lifecycle tests**

Cover queued-to-running acquisition, same-job reacquisition, different-job rejection, retryable running-to-queued with `next_retry_at`, last-attempt failure, succeeded short-circuit, and manual retry replacing `active_job_id`.

```elixir
assert {:ok, running} = WorkerLifecycle.start(node, %Oban.Job{id: 10, attempt: 1, max_attempts: 3})
assert running.status == :running
assert running.active_job_id == 10
assert {:skip, :owned_by_another_job} =
         WorkerLifecycle.start(running, %Oban.Job{id: 11, attempt: 1, max_attempts: 3})
```

- [ ] **Step 2: Run lifecycle tests and observe missing fields/modules**

Run: `mix.bat test test/dramatizer/execution/worker_lifecycle_test.exs`

Expected: failure for missing schema fields and module.

- [ ] **Step 3: Add the migration and NodeRun changeset support**

```elixir
alter table(:node_runs) do
  add :worker, :text
  add :active_job_id, :bigint
  add :lease_expires_at, :utc_datetime_usec
  add :next_retry_at, :utc_datetime_usec
end

create index(:node_runs, [:status, :lease_expires_at])
create index(:node_runs, [:active_job_id])
```

Permit `running -> queued` only through the lifecycle retry function. Clear lease fields on terminal transitions. Resolve persisted Worker names through an explicit registry of application Worker modules; never call `String.to_atom/1` on database data.

- [ ] **Step 4: Implement lifecycle locking and deterministic backoff**

Use `SELECT ... FOR UPDATE`, a five-minute lease, and backoff `min(300, trunc(:math.pow(2, attempt)) * 5)`. Retryable failures before `max_attempts` return `{:retry, reason, seconds}` after restoring queued; the last attempt stores failed. Permanent and unknown-remote failures store stable error codes and never start a new Provider request.

Every lifecycle transition sets Logger metadata for `project_id`, `workflow_run_id`, `node_run_id`, `oban_job_id`, and `attempt`, and logs queue latency, execution duration, retry count, and terminal state without prompt payloads or credentials.

- [ ] **Step 5: Write and run reconciler tests**

Create expired running nodes for: executing Oban job, retryable Oban job, missing job with retry budget, and missing job with exhausted budget. Assert extend, preserve, requeue, and fail outcomes respectively.

Run: `mix.bat test test/dramatizer/execution/worker_lifecycle_test.exs test/dramatizer/execution/reconciler_job_test.exs`

Expected: `0 failures`.

- [ ] **Step 6: Enable periodic and manual reconciliation**

Register `Dramatizer.Execution.ReconcilerJob` in `Oban.Plugins.Cron` with `{"*/1 * * * *", Dramatizer.Execution.ReconcilerJob}` outside test, and expose the same database reconciliation function through `mix dramatizer.execution.reconcile`. The Mix task starts the application, prints counts for extended, preserved, requeued, and failed nodes, and exits nonzero on database failure.

- [ ] **Step 7: Commit**

```powershell
git add app/priv/repo/migrations/20260721090000_add_execution_fields_to_node_runs.exs app/lib/dramatizer/workflow app/lib/dramatizer/workflow.ex app/lib/dramatizer/execution app/lib/mix/tasks/dramatizer.execution.reconcile.ex app/config/config.exs app/test/dramatizer/execution
git commit -m "feat: add durable worker lifecycle"
```

### Task 4: Atomically Enqueue Workflow Nodes

**Files:**
- Create: `app/lib/dramatizer/workflow/enqueue.ex`
- Modify: `app/lib/dramatizer/workflow.ex`
- Modify: `app/lib/dramatizer/workflow/jobs/node_job.ex`
- Modify: `app/test/dramatizer/workflow_test.exs`

**Interfaces:**
- Produces: `Workflow.Enqueue.node/3` returning `{:ok, %{node: NodeRun.t(), job: Oban.Job.t()}}`.
- Consumes: a persisted NodeRun and a worker module implementing `new/2`.

- [ ] **Step 1: Write failing atomic-enqueue tests**

Assert one incomplete job for two enqueue calls, args exactly `%{"node_run_id" => id}`, and `node.active_job_id == job.id`. Force the job insert to fail and assert the NodeRun ownership update rolls back.

- [ ] **Step 2: Run the focused test**

Run: `mix.bat test test/dramatizer/workflow_test.exs`

Expected: failure because `Workflow.Enqueue.node/3` is undefined.

- [ ] **Step 3: Implement Ecto.Multi enqueue**

Use `worker.new(%{"node_run_id" => node.id}, unique: [period: 86_400, fields: [:worker, :args], states: :incomplete])`, `Oban.insert/4`, then update `active_job_id` in the same Multi. Return the conflicting existing job when the unique insert reports conflict.

- [ ] **Step 4: Run tests and commit**

Run: `mix.bat test test/dramatizer/workflow_test.exs`

Expected: `0 failures`.

```powershell
git add app/lib/dramatizer/workflow app/lib/dramatizer/workflow.ex app/test/dramatizer/workflow_test.exs
git commit -m "feat: enqueue workflow nodes atomically"
```

### Task 5: Execute the Analysis DAG Through Oban

**Files:**
- Modify: `app/lib/dramatizer/narrative.ex`
- Modify: `app/lib/dramatizer/analysis.ex`
- Modify: `app/lib/dramatizer/analysis/runner.ex`
- Modify: `app/lib/dramatizer/analysis/jobs/analysis_node_job.ex`
- Modify: `app/test/dramatizer/analysis/dag_test.exs`
- Modify: `app/test/dramatizer/acceptance/source_analysis_test.exs`

**Interfaces:**
- Produces: `Analysis.enqueue(project, source_revision_ids, opts \\ [])` returning `{:ok, WorkflowRun.t()}` without running a Provider.
- Worker args remain `%{"node_run_id" => id}`; Worker uses `WorkerLifecycle` and enqueues newly ready nodes.

- [ ] **Step 1: Write failing enqueue tests**

Inject a submitter that sends the test process a message and assert no message is received during `Analysis.enqueue/3`. Assert three root jobs exist and descendants remain blocked.

- [ ] **Step 2: Run focused tests and confirm synchronous behavior fails**

Run: `mix.bat test test/dramatizer/analysis/dag_test.exs`

Expected: new enqueue assertions fail before production changes.

- [ ] **Step 3: Implement enqueue and single-node worker execution**

Replace `Narrative.ensure_analysis/2` synchronous `Runner.run/3` use with `Analysis.enqueue/3`. `AnalysisNodeJob.perform/1` starts lifecycle, calls `Analysis.run_node_live/3`, marks result, unlocks children, enqueues each child, finalizes the snapshot when all nodes succeed, and broadcasts analysis invalidation.

- [ ] **Step 4: Convert acceptance tests to drain explicit Oban jobs**

Use `assert_enqueued` and `perform_job`/`Oban.drain_queue(queue: :workflow)` rather than relying on the LiveView event to finish the DAG.

- [ ] **Step 5: Run analysis tests and commit**

Run: `mix.bat test test/dramatizer/analysis/dag_test.exs test/dramatizer/acceptance/source_analysis_test.exs`

Expected: `0 failures`.

```powershell
git add app/lib/dramatizer/narrative.ex app/lib/dramatizer/analysis.ex app/lib/dramatizer/analysis app/test/dramatizer/analysis app/test/dramatizer/acceptance/source_analysis_test.exs
git commit -m "feat: run analysis dag with oban"
```

### Task 6: Build the Proposal, Image, and QC Workflow Pipeline

**Files:**
- Create: `app/lib/dramatizer/generation/pipeline.ex`
- Create: `app/lib/dramatizer/generation/jobs/generation_node_job.ex`
- Modify: `app/lib/dramatizer/generation.ex`
- Modify: `app/lib/dramatizer/generation/orchestrator.ex`
- Modify: `app/lib/dramatizer/generation/structured_text_proposal.ex`
- Modify: `app/lib/dramatizer/quality.ex`
- Modify: `app/lib/dramatizer/quality/jobs/technical_qc_job.ex`
- Modify: `app/lib/dramatizer/quality/jobs/semantic_qc_job.ex`
- Create: `app/test/dramatizer/generation/pipeline_test.exs`
- Modify: `app/test/dramatizer/generation/structured_text_proposal_test.exs`
- Modify: `app/test/dramatizer/generation/orchestrator_invariants_test.exs`
- Modify: `app/test/dramatizer/quality/technical_qc_test.exs`
- Modify: `app/test/dramatizer/quality/semantic_qc_test.exs`

**Interfaces:**
- Produces: public `Generation.enqueue_pipeline(project, spec, task_type, opts \\ [])` and `Generation.enqueue_proposal(project, task_type, authority, opts \\ [])`; internal `Generation.Pipeline` owns topology and execution dispatch.
- Node keys: `prompt_proposal`, `asset_generation`, `technical_qc`, `semantic_qc`; proposal-only workflows contain `structured_proposal`.

- [ ] **Step 1: Write failing pipeline topology and no-inline-Provider tests**

Assert image pipelines have the four exact nodes and dependencies, proposal pipelines one node, and enqueue does not invoke injected text/image submitters.

- [ ] **Step 2: Run tests and observe missing pipeline API**

Run: `mix.bat test test/dramatizer/generation/pipeline_test.exs`

Expected: undefined `Dramatizer.Generation.Pipeline`.

- [ ] **Step 3: Implement persisted pipeline definitions and worker dispatch**

Persist only project/spec/revision/reference/config IDs and redacted scalar options in run/node snapshots. `structured_proposal` and `prompt_proposal` call the existing proposal logic inside the worker. `asset_generation` consumes the succeeded prompt node result, prepares ProviderRequestSnapshot/Attempt, and calls the split Orchestrator execution function.

Expose the two public wrapper functions from `Dramatizer.Generation`; callers outside the context do not depend on `Generation.Pipeline` internals.

- [ ] **Step 4: Make QC explicit child nodes**

Remove synchronous `Quality.after_finalize/4` from Orchestrator completion. Asset completion stores the Attempt result, unlocks both QC nodes, and enqueues their existing specialized workers with `node_run_id` only. Each QC worker reads asset/spec IDs from NodeRun input, writes QualityReport, completes lifecycle, and broadcasts.

- [ ] **Step 5: Test success, duplicate enqueue, retry, and unknown remote state**

Use Fake adapters and injected submitters. Assert one Asset and one Attempt terminal effect under duplicate worker execution; unknown remote state does not create Attempt 2 automatically.

- [ ] **Step 6: Run focused suite and commit**

Run: `mix.bat test test/dramatizer/generation test/dramatizer/quality`

Expected: `0 failures`.

```powershell
git add app/lib/dramatizer/generation app/lib/dramatizer/generation.ex app/lib/dramatizer/quality app/lib/dramatizer/quality.ex app/test/dramatizer/generation app/test/dramatizer/quality
git commit -m "feat: add durable generation and qc pipeline"
```

### Task 7: Enqueue Preview and Formal Rendering

**Files:**
- Modify: `app/lib/dramatizer/timeline.ex`
- Modify: `app/lib/dramatizer/timeline/render_recipe.ex`
- Modify: `app/lib/dramatizer/timeline/jobs/render_job.ex`
- Modify: `app/test/dramatizer/timeline/render_recipe_test.exs`
- Modify: `app/test/dramatizer/timeline/render_integration_test.exs`

**Interfaces:**
- Produces: `Timeline.enqueue_render(manifest, opts \\ [])` returning the render WorkflowRun/NodeRun and Job.
- RenderJob args become `%{"node_run_id" => id}`.

- [ ] **Step 1: Write failing asynchronous render tests**

Assert enqueue returns while Manifest is `prepared`, stores a render NodeRun, and inserts one media job. Performing the job yields `rendered`; performing it twice reuses output and SRT Asset IDs.

- [ ] **Step 2: Run focused tests and observe synchronous API failure**

Run: `mix.bat test test/dramatizer/timeline/render_recipe_test.exs test/dramatizer/timeline/render_integration_test.exs`

Expected: new enqueue assertions fail.

- [ ] **Step 3: Implement render workflow envelope and lifecycle**

Build idempotency from project ID, render mode, and recipe hash. RenderJob loads Manifest ID from NodeRun, owns lifecycle, calls `RenderRecipe.render/1`, records domain and node terminal state, and broadcasts timeline invalidation.

- [ ] **Step 4: Run tests and commit**

Run: `mix.bat test test/dramatizer/timeline/render_recipe_test.exs test/dramatizer/timeline/render_integration_test.exs`

Expected: `0 failures`.

```powershell
git add app/lib/dramatizer/timeline.ex app/lib/dramatizer/timeline app/test/dramatizer/timeline
git commit -m "feat: render timelines asynchronously"
```

### Task 8: Connect LiveView to Durable Commands and PubSub

**Files:**
- Create: `app/lib/dramatizer_web/project_workspace/subscription.ex`
- Modify: `app/lib/dramatizer_web/live/project_workspace_live.ex`
- Modify: `app/test/dramatizer_web/live/project_workspace_live_test.exs`

**Interfaces:**
- Produces: `Subscription.subscribe/1` and `Subscription.slice_for/1`.
- LiveView receives `{:execution_changed, event}` and calls resource-specific loaders.

- [ ] **Step 1: Write failing LiveView tests**

Assert analysis, proposal, image, QC, preview, and formal-render buttons enqueue without calling submitters. Assert queued copy appears, repeated click does not add jobs, PubSub refreshes affected assigns, and remount restores persisted status.

- [ ] **Step 2: Run LiveView tests and capture synchronous failures**

Run: `mix.bat test test/dramatizer_web/live/project_workspace_live_test.exs`

Expected: new queued-state assertions fail because handlers currently complete work inline.

- [ ] **Step 3: Replace direct long-running calls with enqueue commands**

Remove every LiveView invocation of `StructuredTextProposal.propose`, `Orchestrator.generate`, `Quality.*.run`, `Timeline.render`, and synchronous analysis Runner. Update flash copy to “已加入队列” and base button disabled state on persisted NodeRun/Manifest facts. Add `phx-disable-with` for the click-to-commit window.

- [ ] **Step 4: Subscribe and reload by resource**

Subscribe only when `connected?(socket)`. Map analysis, generation, quality, timeline, and changes events to focused loader functions; unknown and duplicate notifications are ignored safely. Do not trust event payload as rendered business data.

- [ ] **Step 5: Run tests and commit**

Run: `mix.bat test test/dramatizer_web/live/project_workspace_live_test.exs`

Expected: `0 failures`.

```powershell
git add app/lib/dramatizer_web/project_workspace app/lib/dramatizer_web/live/project_workspace_live.ex app/test/dramatizer_web/live/project_workspace_live_test.exs
git commit -m "feat: make workspace commands asynchronous"
```

### Task 9: Update E2E, Operational Docs, and Run the Full Gate

**Files:**
- Modify: `e2e/tests/fake_animatic.spec.ts`
- Modify: `README.md`
- Modify: `STATUS.md`
- Modify: `docs/implementation-alignment.md`
- Modify: `docs/superpowers/specs/2026-07-21-async-execution-and-truthful-status-design.md`

**Interfaces:**
- Consumes: durable statuses and PubSub-backed UI from Tasks 2–8.
- Produces: verified async E2E and accurate current-truth documentation.

- [ ] **Step 1: Update E2E waits to durable visible states**

After each queued command, wait for explicit `已排队` or `执行中`, then for the persisted stage completion marker. Keep semantic region selectors and explicit human-selection assertions; do not use fixed sleeps.

- [ ] **Step 2: Run the Fake E2E and fix only demonstrated failures**

Run: `.\scripts\e2e.ps1`

Expected: `1 passed` and no listener left on the test port.

- [ ] **Step 3: Update documentation from measured facts**

Describe the Oban/PubSub execution path, retry and recovery behavior, exact verification commands, and any remaining later-phase scope. Remove claims that synchronous return means Provider/QC/render completion.

- [ ] **Step 4: Run the full local verification gate**

Run in order:

```powershell
mix.bat format --check-formatted
mix.bat compile --warnings-as-errors
mix.bat test
mix.bat assets.build
.\scripts\e2e.ps1
```

Expected: every command exits 0; `mix test` reports zero failures; E2E reports `1 passed`.

- [ ] **Step 5: Run explicit real-provider smoke only when credentials are present**

Run: `.\scripts\real-smoke.ps1`

Expected: `PASS`; if credentials are absent, record `NOT RUN: missing explicit credential` rather than weakening ordinary tests.

- [ ] **Step 6: Commit the verified closeout**

```powershell
git add e2e/tests/fake_animatic.spec.ts README.md STATUS.md docs/implementation-alignment.md docs/superpowers/specs/2026-07-21-async-execution-and-truthful-status-design.md
git commit -m "test: verify durable async workspace"
```
