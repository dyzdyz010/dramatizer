defmodule DramatizerWeb.ProjectWorkspaceLive do
  use DramatizerWeb, :live_view

  import Ecto.Query

  alias Dramatizer.Analysis.{AnalysisSnapshot, DAG, Runner}
  alias Dramatizer.Assets
  alias Dramatizer.Assets.AssetVersion
  alias Dramatizer.Changes
  alias Dramatizer.Changes.{ChangeSet, StaleRecord}
  alias Dramatizer.Costs
  alias Dramatizer.Costs.CostEntry
  alias Dramatizer.Directing
  alias Dramatizer.Directing.Compiler
  alias Dramatizer.Generation

  alias Dramatizer.Generation.{
    Attempt,
    ConfigResolver,
    GenerationSpec,
    Orchestrator,
    ProviderRequestSnapshot
  }

  alias Dramatizer.Projects
  alias Dramatizer.Prompts.Catalog
  alias Dramatizer.Quality
  alias Dramatizer.Quality.{QualityReport, SelectionDecision}
  alias Dramatizer.Repo
  alias Dramatizer.Revisions
  alias Dramatizer.Revisions.{Draft, Revision}
  alias Dramatizer.Sources
  alias Dramatizer.Sources.SourceRevision
  alias Dramatizer.Timeline, as: TimelineContext
  alias Dramatizer.Timeline.{Clip, RenderManifest, RenderRecipe, SubtitleCue}
  alias Dramatizer.Timeline.Timeline, as: TimelineRecord
  alias Dramatizer.Visuals
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.{NodeRun, WorkflowRun}
  alias DramatizerWeb.Forms.ModelOverrideForm

  alias DramatizerWeb.Live.Components.{
    CandidateGallery,
    ProjectSettings,
    ProviderStatus,
    RunPanel,
    StageNav,
    TimelineEditor
  }

  @stages ~w(source analysis episodes visuals shots timeline runs)a
  @image_extensions ~w(.png .jpg .jpeg .webp)

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_project!(id)

    socket =
      socket
      |> assign(:project, project)
      |> assign(:page_title, project.name)
      |> assign(:json_form, to_form(%{"payload" => "{}"}, as: :draft))
      |> assign(:visual_form, visual_form())
      |> assign(:shot_form, shot_form())
      |> assign(:impact, nil)
      |> allow_upload(:source,
        accept: ~w(.txt .md .markdown .pdf),
        auto_upload: true,
        max_entries: 5,
        max_file_size: 100_000_000
      )
      |> allow_upload(:media,
        accept: @image_extensions,
        auto_upload: true,
        max_entries: 12,
        max_file_size: 25_000_000
      )
      |> load_workspace()

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket) do
    stage = socket.assigns.live_action
    {:noreply, socket |> assign(:stage, stage) |> load_workspace()}
  end

  @impl Phoenix.LiveView
  def handle_event("validate-upload", _params, socket), do: {:noreply, socket}

  def handle_event("rename-project", %{"project" => %{"name" => name}}, socket) do
    result = Projects.rename_project(socket.assigns.project, String.trim(name))

    socket =
      case result do
        {:ok, project} ->
          socket
          |> assign(:project, project)
          |> put_flash(:info, "项目名称已更新。")
          |> load_workspace()

        {:error, reason} ->
          put_flash(socket, :error, human_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("update-production-profile", %{"profile" => attrs}, socket) do
    result = Projects.update_production_profile(socket.assigns.project, attrs)
    {:noreply, result_flash(socket, result, "项目 ProductionProfile 已更新。") |> load_workspace()}
  end

  def handle_event(
        "put-model-override",
        %{"_action" => "delete", "model_override" => %{"task_type" => task_type}},
        socket
      ) do
    result =
      with {:ok, task} <- model_task_type(task_type) do
        Projects.delete_model_override(socket.assigns.project, task)
      end

    {:noreply, result_flash(socket, result, "项目模型覆盖已清除，已恢复继承。") |> load_workspace()}
  end

  def handle_event(
        "put-model-override",
        %{"model_override" => %{"task_type" => task_type} = params},
        socket
      ) do
    result =
      with {:ok, task} <- model_task_type(task_type),
           {:ok, attrs} <- ModelOverrideForm.cast(task, params) do
        Projects.put_model_override(socket.assigns.project, task, attrs)
      else
        _ -> {:error, :invalid_model_override}
      end

    {:noreply, result_flash(socket, result, "项目模型覆盖已保存。") |> load_workspace()}
  end

  def handle_event("update-budget", %{"budget" => %{"limit_units" => value}}, socket) do
    result =
      case String.trim(value) do
        "" -> Costs.clear_budget_limit(socket.assigns.project)
        amount -> parse_budget_micros(amount, socket.assigns.project)
      end

    {:noreply, result_flash(socket, result, "项目预算已更新。") |> load_workspace()}
  end

  def handle_event(
        "create-prompt-appendix",
        %{"prompt_appendix" => %{"task_type" => task_type, "body" => body}},
        socket
      ) do
    result =
      with {:ok, task} <- prompt_task_type(task_type),
           false <- String.trim(body) == "" do
        Projects.create_prompt_appendix(socket.assigns.project, task, String.trim(body))
      else
        true -> {:error, :prompt_appendix_required}
        error -> error
      end

    {:noreply, result_flash(socket, result, "PromptAppendix 新 Revision 已保存。") |> load_workspace()}
  end

  def handle_event("import-source", _params, socket) do
    results =
      consume_uploaded_entries(socket, :source, fn %{path: path}, entry ->
        import_dir =
          Path.join(
            System.tmp_dir!(),
            "dramatizer-live-import-#{System.unique_integer([:positive])}"
          )

        copied = Path.join(import_dir, Path.basename(entry.client_name))
        File.mkdir_p!(import_dir)
        File.cp!(path, copied)
        result = Sources.import(socket.assigns.project, copied)
        File.rm_rf(import_dir)
        {:ok, result}
      end)

    socket =
      case results do
        [] ->
          put_flash(socket, :error, "请先选择文件并等待上传完成。")

        results ->
          case Enum.find(results, &match?({:error, _}, &1)) do
            nil -> socket |> put_flash(:info, "原著已按全文解析并落盘。") |> load_workspace()
            {:error, reason} -> put_flash(socket, :error, human_error(reason))
          end
      end

    {:noreply, socket}
  end

  def handle_event("import-media", _params, socket) do
    results =
      consume_uploaded_entries(socket, :media, fn %{path: path}, entry ->
        attrs = %{
          purpose: "user-reference",
          expected_mime: entry.client_type,
          idempotency_key:
            "live-upload:#{socket.assigns.project.id}:#{entry.client_name}:#{entry.ref}"
        }

        {:ok, Assets.import_file(socket.assigns.project, path, attrs)}
      end)

    socket =
      case results do
        [] ->
          put_flash(socket, :error, "请先选择图片并等待上传完成。")

        results ->
          case Enum.find(results, &match?({:error, _}, &1)) do
            nil -> socket |> put_flash(:info, "参考图已进入统一 AssetStore。") |> load_workspace()
            {:error, reason} -> put_flash(socket, :error, human_error(reason))
          end
      end

    {:noreply, socket}
  end

  def handle_event("start-analysis", _params, socket) do
    revision_ids = Enum.map(socket.assigns.source_revisions, & &1.id)

    socket =
      case DAG.start(socket.assigns.project, revision_ids) do
        {:ok, run, _nodes} ->
          mode = Application.fetch_env!(:dramatizer, :provider_mode)

          case Runner.run(socket.assigns.project, run, mode) do
            {:ok, _snapshot} ->
              socket
              |> put_flash(:info, "全文分析 DAG 已完成并冻结 AnalysisSnapshot。")
              |> load_workspace()

            {:error, reason} ->
              socket |> put_flash(:error, human_error(reason)) |> load_workspace()
          end

        {:error, reason} ->
          put_flash(socket, :error, human_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("retry-node", %{"id" => id}, socket) do
    result = id |> Repo.get!(NodeRun) |> Workflow.retry_node()
    {:noreply, result_flash(socket, result, "节点已重新排队。") |> load_workspace()}
  end

  def handle_event("select-episode", %{"candidate-id" => candidate_id}, socket) do
    snapshot = List.first(socket.assigns.analysis_snapshots)

    result =
      if snapshot do
        Dramatizer.Narrative.materialize_episode(socket.assigns.project, snapshot, candidate_id)
      else
        {:error, :analysis_snapshot_required}
      end

    {:noreply, result_flash(socket, result, "已创建可编辑 Narrative 草稿。") |> load_workspace()}
  end

  def handle_event("update-draft", %{"id" => id, "draft" => %{"payload" => payload}}, socket) do
    result =
      with {:ok, decoded} <- Jason.decode(payload),
           true <- is_map(decoded),
           draft <- Repo.get!(Draft, id) do
        Revisions.update_draft(draft, decoded)
      else
        false -> {:error, :json_object_required}
        {:error, _} -> {:error, :invalid_json}
      end

    {:noreply, result_flash(socket, result, "草稿已保存。") |> load_workspace()}
  end

  def handle_event("confirm-draft", %{"id" => id}, socket) do
    {:noreply,
     result_flash(socket, Revisions.confirm_draft(id), "已冻结为不可变 Revision。")
     |> load_workspace()}
  end

  def handle_event("create-visual-design", %{"visual" => %{"objects" => json}}, socket) do
    narrative = latest_revision(socket.assigns.revisions, :narrative)

    result =
      with {:ok, objects} when is_list(objects) <- Jason.decode(json) do
        Visuals.create_design_draft(socket.assigns.project, narrative, objects)
      else
        _ -> {:error, :invalid_visual_objects}
      end

    {:noreply, result_flash(socket, result, "视觉设计草稿已创建。") |> load_workspace()}
  end

  def handle_event("create-shot-plan", %{"shot" => %{"proposal" => json}}, socket) do
    narrative = latest_revision(socket.assigns.revisions, :narrative)
    visual = latest_revision(socket.assigns.revisions, :visual_design)

    result =
      with {:ok, proposal} when is_map(proposal) <- Jason.decode(json) do
        Directing.create_shot_plan_draft(socket.assigns.project, narrative, visual, proposal)
      else
        _ -> {:error, :invalid_shot_plan}
      end

    {:noreply, result_flash(socket, result, "ShotPlan 草稿已创建。") |> load_workspace()}
  end

  def handle_event(
        "create-reference-set",
        %{"reference" => %{"assignments" => assignments}},
        socket
      ) do
    visual = latest_revision(socket.assigns.revisions, :visual_design)
    cleaned = Map.reject(assignments, fn {_slot, asset_id} -> asset_id == "" end)

    result =
      if visual do
        Visuals.create_reference_set_draft(socket.assigns.project, visual, cleaned)
      else
        {:error, :confirmed_visual_design_required}
      end

    {:noreply, result_flash(socket, result, "ReferenceSet 草稿已创建。") |> load_workspace()}
  end

  def handle_event("generate-reference-candidates", _params, socket) do
    visual = latest_revision(socket.assigns.revisions, :visual_design)

    result =
      with %Revision{} = visual <- visual,
           {:ok, specs} <- materialize_reference_specs(socket.assigns.project, visual) do
        Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, generated} ->
          case Orchestrator.generate(spec, :reference_image, socket.assigns.project) do
            {:ok, candidate} -> {:cont, {:ok, [candidate | generated]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      else
        nil -> {:error, :confirmed_visual_design_required}
        error -> error
      end

    {:noreply,
     result_flash(socket, result, "参考图候选及 QC 已完成，等待逐槽位选择。")
     |> load_workspace()}
  end

  def handle_event("create-reference-set-from-selections", _params, socket) do
    visual = latest_revision(socket.assigns.revisions, :visual_design)

    assignments =
      Map.new(socket.assigns.reference_slots, fn slot ->
        selection =
          Enum.find(socket.assigns.selections, &(&1.slot_key == "reference:#{slot}"))

        {slot, selection && selection.asset_version_id}
      end)
      |> Map.reject(fn {_slot, asset_id} -> is_nil(asset_id) end)

    result =
      if visual do
        Visuals.create_reference_set_draft(socket.assigns.project, visual, assignments)
      else
        {:error, :confirmed_visual_design_required}
      end

    {:noreply, result_flash(socket, result, "ReferenceSet 草稿已由明确选择创建。") |> load_workspace()}
  end

  def handle_event(
        "edit-candidate",
        %{
          "asset-id" => asset_id,
          "spec-id" => spec_id,
          "slot-key" => slot_key,
          "edit" => %{"instruction" => instruction}
        },
        socket
      ) do
    parent = Repo.get!(AssetVersion, asset_id)
    parent_spec = Repo.get!(GenerationSpec, spec_id)

    payload =
      parent_spec.payload
      |> Map.put("prompt", String.trim(instruction))
      |> Map.put("parent_asset_id", parent.id)
      |> Map.put("reference_asset_ids", [parent.id])
      |> Map.put("slot_key", slot_key)

    result =
      with false <- String.trim(instruction) == "",
           {:ok, spec} <-
             Generation.create_spec(socket.assigns.project, %{
               revision_id: parent_spec.revision_id,
               kind: "image_edit",
               formal: parent_spec.formal,
               payload: payload
             }),
           {:ok, generated} <-
             Orchestrator.generate(spec, :image_edit, socket.assigns.project,
               reference_assets: [parent]
             ) do
        {:ok, generated}
      else
        true -> {:error, :edit_instruction_required}
        error -> error
      end

    {:noreply, result_flash(socket, result, "图像编辑已创建不可变子版本。") |> load_workspace()}
  end

  def handle_event("compile-shot-specs", _params, socket) do
    inputs = %{
      narrative: latest_revision(socket.assigns.revisions, :narrative),
      visual_design: latest_revision(socket.assigns.revisions, :visual_design),
      reference_set: latest_revision(socket.assigns.revisions, :reference_set),
      shot_plan: latest_revision(socket.assigns.revisions, :shot_plan)
    }

    source_revision_ids = Enum.map(socket.assigns.source_revisions, & &1.id)

    result =
      with {:ok, compiled_revision} <-
             Compiler.compile_revision(socket.assigns.project, inputs,
               source_revision_ids: source_revision_ids
             ),
           :ok <- materialize_generation_specs(socket.assigns.project, compiled_revision) do
        {:ok, compiled_revision}
      end

    {:noreply, result_flash(socket, result, "确定性 GenerationSpec 已编译。") |> load_workspace()}
  end

  def handle_event("generate-shot-candidates", _params, socket) do
    specs = Enum.filter(socket.assigns.specs, &(&1.kind == "shot_keyframe"))

    result =
      Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, results} ->
        case Orchestrator.generate(spec, :shot_keyframe, socket.assigns.project) do
          {:ok, generated} -> {:cont, {:ok, [generated | results]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    {:noreply, result_flash(socket, result, "候选图及 QC 已完成，等待人工选择。") |> load_workspace()}
  end

  def handle_event("inject-fake-failure", _params, socket) do
    {:ok, spec} = fake_fault_spec(socket.assigns.project)

    result =
      Orchestrator.generate(spec, :shot_keyframe, socket.assigns.project,
        fault_profile: fake_fault_profile()
      )

    socket =
      case result do
        {:error, :provider_rejected} -> put_flash(socket, :info, "Fake 首次提交已按计划失败。")
        other -> result_flash(socket, other, "Fake 故障节点已执行。")
      end

    {:noreply, load_workspace(socket)}
  end

  def handle_event("resume-fake-failure", _params, socket) do
    {:ok, spec} = fake_fault_spec(socket.assigns.project)

    result =
      Orchestrator.generate(spec, :shot_keyframe, socket.assigns.project,
        fault_profile: fake_fault_profile()
      )

    {:noreply,
     result_flash(socket, result, "Fake 节点已恢复；重复/乱序回调已去重。")
     |> load_workspace()}
  end

  def handle_event("derive-draft", %{"revision-id" => id}, socket) do
    {:noreply,
     result_flash(socket, Revisions.derive_draft(id), "已从冻结 Revision 派生新草稿。")
     |> load_workspace()}
  end

  def handle_event("preview-change", %{"old-id" => old_id, "new-id" => new_id}, socket) do
    result =
      Changes.preview(
        socket.assigns.project,
        Revisions.get_revision!(old_id),
        Revisions.get_revision!(new_id)
      )

    case result do
      {:ok, impact} -> {:noreply, assign(socket, :impact, impact)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, human_error(reason))}
    end
  end

  def handle_event("confirm-change", _params, %{assigns: %{impact: impact}} = socket)
      when not is_nil(impact) do
    result = Changes.confirm(impact, :all)

    {:noreply,
     socket
     |> assign(:impact, nil)
     |> result_flash(result, "ChangeSet 影响范围已明确确认。")
     |> load_workspace()}
  end

  def handle_event(
        "select-candidate",
        %{"asset-id" => asset_id, "spec-id" => spec_id, "slot-key" => slot_key},
        socket
      ) do
    result =
      Quality.select(
        socket.assigns.project,
        slot_key,
        Repo.get!(GenerationSpec, spec_id),
        Repo.get!(AssetVersion, asset_id)
      )

    {:noreply, result_flash(socket, result, "候选已明确选中，历史选择仍保留。") |> load_workspace()}
  end

  def handle_event("resolve-stale", %{"selection-id" => id}, socket) do
    result = id |> Repo.get!(SelectionDecision) |> Changes.resolve_stale(:pin_old_input)
    {:noreply, result_flash(socket, result, "已固定旧输入闭包。") |> load_workspace()}
  end

  def handle_event("resume-change", %{"id" => id}, socket) do
    result = id |> Repo.get!(ChangeSet) |> Changes.resume()
    {:noreply, result_flash(socket, result, "ChangeSet 已恢复执行。") |> load_workspace()}
  end

  def handle_event("create-timeline", _params, socket) do
    narrative = latest_revision(socket.assigns.revisions, :narrative)
    shot_plan = latest_revision(socket.assigns.revisions, :shot_plan)

    selections =
      Map.new(socket.assigns.selections, fn selection ->
        {String.replace_prefix(selection.slot_key, "shot:", ""), selection}
      end)

    result =
      if narrative && shot_plan do
        TimelineContext.create(socket.assigns.project, narrative, shot_plan, selections)
      else
        {:error, :confirmed_timeline_inputs_required}
      end

    {:noreply, result_flash(socket, result, "时间线草稿已创建。") |> load_workspace()}
  end

  def handle_event("move-clip", %{"id" => id, "position" => position}, socket) do
    result = TimelineContext.move_clip(socket.assigns.timeline, id, String.to_integer(position))
    {:noreply, result_flash(socket, result, "镜头顺序已更新。") |> load_workspace()}
  end

  def handle_event("update-clip", %{"id" => id, "clip" => attrs}, socket) do
    clip = Repo.get!(Clip, id)

    result =
      with {:ok, duration} <- parse_positive_integer(attrs["duration_ms"]),
           {:ok, transition_duration} <-
             parse_non_negative_integer(attrs["transition_duration_ms"]),
           {:ok, motion} <- parse_motion(attrs["motion"]),
           {:ok, transition} <- parse_transition(attrs["transition_after"]) do
        TimelineContext.update_clip(clip, %{
          duration_ms: duration,
          motion: motion,
          transition_after: transition,
          transition_duration_ms: transition_duration
        })
      end

    {:noreply, result_flash(socket, result, "镜头时长、运动与转场已保存。") |> load_workspace()}
  end

  def handle_event("add-placeholder-clip", _params, socket) do
    result =
      with %TimelineRecord{} = timeline <- socket.assigns.timeline do
        next = length(socket.assigns.clips) + 1

        TimelineContext.add_clip(timeline, %{
          shot_id: "ADDED-#{String.pad_leading(Integer.to_string(next), 3, "0")}",
          position: next,
          duration_ms: 1_000,
          motion: :static
        })
      else
        nil -> {:error, :timeline_required}
      end

    {:noreply, result_flash(socket, result, "已添加可编辑占位镜头。") |> load_workspace()}
  end

  def handle_event("remove-clip", %{"id" => id}, socket) do
    result = TimelineContext.remove_clip(socket.assigns.timeline, Repo.get!(Clip, id))
    {:noreply, result_flash(socket, result, "镜头已从时间线草稿移除。") |> load_workspace()}
  end

  def handle_event(
        "replace-clip",
        %{"id" => id, "replacement" => %{"selection_id" => selection_id}},
        socket
      ) do
    result =
      TimelineContext.replace_clip(
        Repo.get!(Clip, id),
        Repo.get!(SelectionDecision, selection_id)
      )

    {:noreply, result_flash(socket, result, "镜头已替换为明确选择的资产。") |> load_workspace()}
  end

  def handle_event(
        "update-subtitle",
        %{
          "id" => id,
          "cue" => %{
            "text" => text,
            "start_ms" => start_ms,
            "end_ms" => end_ms,
            "position" => position
          }
        },
        socket
      ) do
    cue = Repo.get!(SubtitleCue, id)

    result =
      TimelineContext.update_subtitle(cue, %{
        text: text,
        start_ms: String.to_integer(start_ms),
        end_ms: String.to_integer(end_ms),
        style: Map.put(cue.style, "position", position)
      })

    {:noreply, result_flash(socket, result, "字幕已保存，不会改写 Narrative。") |> load_workspace()}
  end

  def handle_event("preview-timeline", _params, socket) do
    result =
      with %TimelineRecord{} = timeline <- socket.assigns.timeline,
           {:ok, manifest} <- RenderRecipe.preview(timeline) do
        TimelineContext.render(manifest)
      else
        nil -> {:error, :timeline_required}
        error -> error
      end

    {:noreply, result_flash(socket, result, "预览已完成。") |> load_workspace()}
  end

  def handle_event("freeze-timeline", _params, socket) do
    result =
      with %TimelineRecord{} = timeline <- socket.assigns.timeline,
           {:ok, version} <- TimelineContext.freeze(timeline),
           {:ok, manifest} <- RenderRecipe.formal(version) do
        TimelineContext.render(manifest)
      else
        nil -> {:error, :timeline_required}
        error -> error
      end

    {:noreply, result_flash(socket, result, "正式成片与 SRT 已落盘。") |> load_workspace()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="workspace-shell">
        <header class="project-header">
          <div>
            <.link navigate={~p"/"} class="back-link">← 全部项目</.link>
            <p class="eyebrow">CURRENT PROJECT</p>
            <h1>{@project.name}</h1>
            <form id="rename-project-form" phx-submit="rename-project" class="inline-setting-form">
              <label>
                <span class="sr-only">项目名称</span>
                <input type="text" name="project[name]" value={@project.name} required />
              </label>
              <button type="submit" class="btn btn-ghost">改名</button>
            </form>
          </div>
          <div class="project-header__status">
            <ProviderStatus.provider_status
              mode={@provider_mode}
              credential_available={@credential_available}
              text_model={@text_model}
              image_model={@image_model}
            />
            <span>当前阶段</span>
            <strong>{stage_title(@stage)}</strong>
            <.state_badge state={@state} />
          </div>
        </header>

        <StageNav.stage_nav project={@project} current={@stage} states={@stage_states} />

        <main class="workspace-main" data-stage={@stage} data-state={@state}>
          <section class="stage-intro">
            <div>
              <p class="eyebrow">{stage_code(@stage)}</p>
              <h2>{stage_title(@stage)}</h2>
              <p>{stage_description(@stage)}</p>
            </div>
            <.state_badge state={@state} />
          </section>

          <section :if={@stage == :source} class="workspace-panel">
            <div class="two-column">
              <div>
                <h3>导入小说全文</h3>
                <p class="muted">支持 TXT、Markdown 与带文本层 PDF；整本一次进入解析器。</p>
                <form
                  id="source-upload-form"
                  phx-change="validate-upload"
                  phx-submit="import-source"
                  class="upload-zone"
                >
                  <.live_file_input upload={@uploads.source} />
                  <.icon name="hero-arrow-up-tray" class="size-8" />
                  <strong>选择或拖入原著文件</strong>
                  <span>单文件上限 100 MB</span>
                  <div :for={entry <- @uploads.source.entries} class="upload-progress">
                    <span>{entry.client_name}</span><progress value={entry.progress} max="100"></progress>
                  </div>
                  <button
                    class="btn btn-primary"
                    type="submit"
                    disabled={upload_unready?(@uploads.source.entries)}
                  >
                    解析并落盘
                  </button>
                </form>
              </div>
              <div>
                <h3>已解析来源</h3>
                <div :if={@source_revisions == []} class="empty-panel compact">等待导入第一份原著。</div>
                <article :for={revision <- @source_revisions} class="source-row">
                  <div>
                    <strong>{revision.original_filename}</strong>
                    <p>已解析全文 · {revision.character_count} 字 · rev {revision.revision}</p>
                  </div>
                  <.state_badge state={:ready} />
                </article>
              </div>
            </div>
          </section>

          <section :if={@stage == :analysis} class="workspace-panel" data-human-gate>
            <div class="panel-actions">
              <button
                type="button"
                class="btn btn-primary"
                phx-click="start-analysis"
                disabled={@source_revisions == []}
              >
                启动全文分析
              </button>
              <span>六节点 DAG · 结构化校验 · 最多两次修复</span>
            </div>
            <div class="dag-grid">
              <article :for={node <- @nodes} class="dag-node">
                <span class="eyebrow">{node.node_key}</span>
                <h3>{node_label(node.node_key)}</h3>
                <.state_badge state={node_state(node.status)} />
                <p :if={node.error_code} class="error-copy">{node.error_code}</p>
                <button
                  :if={node.status == :failed}
                  type="button"
                  class="btn btn-ghost"
                  phx-click="retry-node"
                  phx-value-id={node.id}
                >
                  仅重试本节点
                </button>
              </article>
            </div>
          </section>

          <section :if={@stage == :episodes} class="workspace-panel" data-human-gate>
            <div class="candidate-list">
              <article :for={candidate <- @episode_candidates} class="episode-card">
                <div>
                  <span class="eyebrow">{candidate["id"]}</span>
                  <h3>{candidate["name"]}</h3>
                  <p>{candidate["data"]["summary"] || "来自全文分析的候选集"}</p>
                </div>
                <button
                  type="button"
                  class="btn btn-primary"
                  phx-click="select-episode"
                  phx-value-candidate-id={candidate["id"]}
                >
                  选择并创建 Narrative
                </button>
              </article>
            </div>
            <.draft_editor :for={draft <- drafts_for(@drafts, :narrative)} draft={draft} />
            <div
              :if={@episode_candidates == [] and drafts_for(@drafts, :narrative) == []}
              class="empty-panel compact"
            >
              全文分析完成后，请在此明确选择一个分集候选。
            </div>
          </section>

          <section :if={@stage == :visuals} class="workspace-panel" data-human-gate>
            <div class="two-column">
              <.form for={@visual_form} phx-submit="create-visual-design" class="structured-form">
                <h3>建立视觉权威草稿</h3>
                <.input
                  field={@visual_form[:objects]}
                  type="textarea"
                  label="角色／场景／道具对象 JSON"
                  rows="14"
                />
                <.button variant="primary">创建 VisualDesign</.button>
              </.form>
              <form
                id="media-upload-form"
                phx-change="validate-upload"
                phx-submit="import-media"
                class="upload-zone media-upload"
              >
                <.live_file_input upload={@uploads.media} />
                <.icon name="hero-photo" class="size-8" />
                <strong>上传参考图</strong>
                <span>PNG、JPG、JPEG、WEBP</span>
                <div :for={entry <- @uploads.media.entries} class="upload-progress">
                  <span>{entry.client_name}</span><progress value={entry.progress} max="100"></progress>
                </div>
                <button
                  class="btn btn-primary"
                  type="submit"
                  disabled={upload_unready?(@uploads.media.entries)}
                >
                  存入素材库
                </button>
              </form>
            </div>
            <.draft_editor :for={draft <- drafts_for(@drafts, :visual_design)} draft={draft} />
            <div :if={@reference_slots != []} class="panel-actions production-actions">
              <button type="button" class="btn btn-primary" phx-click="generate-reference-candidates">
                AI 生成参考候选
              </button>
              <button
                type="button"
                class="btn btn-soft"
                phx-click="create-reference-set-from-selections"
              >
                从已选主图创建 ReferenceSet
              </button>
            </div>
            <CandidateGallery.candidate_gallery candidates={@reference_candidates} />
            <.form
              :if={@reference_slots != []}
              for={to_form(%{}, as: :reference)}
              id="reference-set-form"
              phx-submit="create-reference-set"
              class="structured-form"
            >
              <div class="section-heading compact">
                <div>
                  <p class="eyebrow">PRIMARY REFERENCES</p>
                  <h3>逐槽位选择主参考图</h3>
                </div>
                <span class="count-pill">{length(@reference_slots)}</span>
              </div>
              <div class="reference-slot-grid">
                <label :for={slot <- @reference_slots}>
                  <span>{slot}</span>
                  <select name={"reference[assignments][#{slot}]"} class="select w-full">
                    <option value="">请选择，不自动指定</option>
                    <option :for={asset <- @reference_assets} value={asset.id}>
                      {String.slice(asset.blob_hash, 0, 12)} · {asset.width}×{asset.height}
                    </option>
                  </select>
                </label>
              </div>
              <.button variant="primary">创建 ReferenceSet 草稿</.button>
            </.form>
            <.draft_editor :for={draft <- drafts_for(@drafts, :reference_set)} draft={draft} />
          </section>

          <section :if={@stage == :shots} class="workspace-panel" data-human-gate>
            <.form for={@shot_form} phx-submit="create-shot-plan" class="structured-form">
              <h3>导演方案与镜头节奏</h3>
              <.input field={@shot_form[:proposal]} type="textarea" label="ShotPlan JSON" rows="12" />
              <.button variant="primary">创建 ShotPlan 草稿</.button>
            </.form>
            <.draft_editor :for={draft <- drafts_for(@drafts, :shot_plan)} draft={draft} />
            <div class="panel-actions production-actions">
              <button type="button" class="btn btn-soft" phx-click="compile-shot-specs">
                编译冻结 GenerationSpec
              </button>
              <button
                type="button"
                class="btn btn-primary"
                phx-click="generate-shot-candidates"
                disabled={Enum.all?(@specs, &(&1.kind != "shot_keyframe"))}
              >
                生成候选并执行 QC
              </button>
            </div>
            <CandidateGallery.candidate_gallery candidates={@shot_candidates} />
            <div :for={stale <- @stale_records} class="stale-row">
              <div>
                <strong>选择输入已过期</strong>
                <p>{stale.reason}</p>
              </div>
              <button
                type="button"
                class="btn btn-ghost"
                phx-click="resolve-stale"
                phx-value-selection-id={stale.subject_id}
              >
                固定旧输入
              </button>
            </div>
          </section>

          <section :if={@stage == :timeline} class="workspace-panel" data-human-gate>
            <TimelineEditor.timeline_editor
              timeline={@timeline}
              clips={@clips}
              subtitles={@subtitles}
              renders={@renders}
              selections={shot_selections(@selections)}
            />
          </section>

          <section :if={@stage == :runs} class="workspace-panel">
            <ProjectSettings.project_settings
              profile={@profile}
              budget={@budget}
              model_task_types={@model_task_types}
              prompt_task_types={@prompt_task_types}
            />
            <div
              :if={Application.fetch_env!(:dramatizer, :provider_mode) == :fake}
              class="fake-controls"
              data-human-gate
            >
              <div>
                <p class="eyebrow">OFFLINE RECOVERY CONTROL</p>
                <h3>Fake 故障与幂等烟测</h3>
                <p>首次提交失败；恢复时注入重复与乱序回调，验证只产生一个结果和一笔实际成本。</p>
              </div>
              <div>
                <button type="button" class="btn btn-soft" phx-click="inject-fake-failure">
                  注入一次 Fake 失败
                </button>
                <button type="button" class="btn btn-primary" phx-click="resume-fake-failure">
                  恢复并注入重复乱序回调
                </button>
              </div>
            </div>
            <RunPanel.run_panel runs={@runs} attempts={@attempts} costs={@costs} />
            <div :for={{old_revision, new_revision} <- @revision_pairs} class="trace-row">
              <div>
                <strong>
                  {kind_label(new_revision.kind)} rev {old_revision.revision} → {new_revision.revision}
                </strong>
                <p>先预览精确依赖影响，再创建 ChangeSet。</p>
              </div>
              <button
                type="button"
                class="btn btn-ghost"
                phx-click="preview-change"
                phx-value-old-id={old_revision.id}
                phx-value-new-id={new_revision.id}
              >
                预览影响
              </button>
            </div>
            <article :if={@impact} class="impact-panel" data-human-gate>
              <div>
                <p class="eyebrow">CHANGESET PREVIEW · EPOCH {@impact.graph_epoch}</p>
                <h3>确认影响范围</h3>
                <p>{@impact.diff["kind"]} · {length(@impact.targets)} 个精确下游目标</p>
              </div>
              <ul>
                <li :for={target <- @impact.targets}>{target.type} · {target.id}</li>
              </ul>
              <button type="button" class="btn btn-primary" phx-click="confirm-change">
                确认全部列出的影响
              </button>
            </article>
            <div :for={change <- @change_sets} class="trace-row">
              <div>
                <strong>ChangeSet · epoch {change.graph_epoch}</strong>
                <p>{change.status} · {length(change.selected_target_ids)} 个目标</p>
              </div>
              <button
                :if={change.status == :partial_failed}
                type="button"
                class="btn btn-ghost"
                phx-click="resume-change"
                phx-value-id={change.id}
              >
                恢复未完成节点
              </button>
            </div>
          </section>

          <div id="state-legend" class="state-legend" aria-label="状态图例">
            <.state_badge
              :for={state <- [:empty, :loading, :failed, :ready, :waiting_user, :stale]}
              state={state}
            />
          </div>
        </main>
      </div>
    </Layouts.app>
    """
  end

  attr :draft, :map, required: true

  defp draft_editor(assigns) do
    assigns = assign(assigns, :form, draft_form(assigns.draft))

    ~H"""
    <article class="draft-editor">
      <div class="section-heading compact">
        <div>
          <span class="eyebrow">EDITABLE AUTHORITY</span>
          <h3>{kind_label(@draft.kind)} 草稿</h3>
        </div>
        <.state_badge state={if @draft.status == :confirmed, do: :ready, else: :waiting_user} />
      </div>
      <.form
        :if={@draft.status == :editing}
        for={@form}
        id={"draft-#{@draft.id}"}
        phx-submit="update-draft"
        phx-value-id={@draft.id}
      >
        <.input field={@form[:payload]} type="textarea" label="结构化内容" rows="12" />
        <div class="form-actions">
          <button type="submit" class="btn btn-soft">保存修改</button>
          <button
            type="button"
            class="btn btn-primary"
            phx-click="confirm-draft"
            phx-value-id={@draft.id}
          >
            确认并冻结 Revision
          </button>
        </div>
      </.form>
      <pre :if={@draft.status == :confirmed} class="json-preview">{Jason.encode!(@draft.payload, pretty: true)}</pre>
      <button
        :if={@draft.status == :confirmed and @draft.confirmed_revision_id}
        type="button"
        class="btn btn-ghost"
        phx-click="derive-draft"
        phx-value-revision-id={@draft.confirmed_revision_id}
      >
        从此 Revision 派生修改
      </button>
    </article>
    """
  end

  defp load_workspace(socket) do
    project_id = socket.assigns.project.id

    source_revisions =
      Repo.all(
        from revision in SourceRevision,
          where: revision.project_id == ^project_id,
          order_by: [asc: revision.inserted_at]
      )

    runs =
      Repo.all(
        from run in WorkflowRun,
          where: run.project_id == ^project_id,
          order_by: [desc: run.inserted_at]
      )

    run_ids = Enum.map(runs, & &1.id)

    nodes =
      if run_ids == [] do
        []
      else
        Repo.all(
          from node in NodeRun,
            where: node.workflow_run_id in ^run_ids,
            order_by: [desc: node.inserted_at]
        )
      end

    snapshots =
      Repo.all(
        from snapshot in AnalysisSnapshot,
          where: snapshot.project_id == ^project_id,
          order_by: [desc: snapshot.inserted_at]
      )

    drafts =
      Repo.all(
        from draft in Draft,
          where: draft.project_id == ^project_id,
          order_by: [desc: draft.inserted_at]
      )

    revisions =
      Repo.all(
        from revision in Revision,
          where: revision.project_id == ^project_id,
          order_by: [desc: revision.inserted_at]
      )

    specs = Repo.all(from spec in GenerationSpec, where: spec.project_id == ^project_id)
    assets = Repo.all(from asset in AssetVersion, where: asset.project_id == ^project_id)

    reports =
      Repo.all(
        from report in QualityReport,
          where: report.project_id == ^project_id,
          order_by: [desc: report.inserted_at]
      )

    selections =
      Repo.all(
        from selection in SelectionDecision,
          where: selection.project_id == ^project_id and selection.status == :active
      )

    stale_records =
      Repo.all(
        from stale in StaleRecord,
          where: stale.project_id == ^project_id and stale.resolution == :unresolved,
          order_by: [desc: stale.inserted_at]
      )

    timeline =
      Repo.one(
        from timeline in TimelineRecord,
          where: timeline.project_id == ^project_id,
          order_by: [desc: timeline.inserted_at],
          limit: 1
      )

    clips = if timeline, do: TimelineContext.list_clips(timeline), else: []
    subtitles = if timeline, do: TimelineContext.list_subtitles(timeline), else: []

    renders =
      Repo.all(
        from manifest in RenderManifest,
          where: manifest.project_id == ^project_id,
          order_by: [desc: manifest.inserted_at]
      )

    attempts = attempt_traces(project_id)
    costs = Repo.all(from cost in CostEntry, where: cost.project_id == ^project_id)

    change_sets =
      Repo.all(
        from change in ChangeSet,
          where: change.project_id == ^project_id,
          order_by: [desc: change.inserted_at]
      )

    candidates = build_candidates(assets, specs, reports, selections, attempts, costs)

    reference_candidates =
      Enum.filter(candidates, &String.starts_with?(&1.slot_key, "reference:"))

    shot_candidates = Enum.filter(candidates, &String.starts_with?(&1.slot_key, "shot:"))
    episode_candidates = episode_candidates(snapshots)
    reference_slots = reference_slots(revisions)
    reference_assets = Enum.filter(assets, &String.starts_with?(&1.mime_type, "image/"))

    stage_states =
      stage_states(%{
        source_revisions: source_revisions,
        runs: runs,
        nodes: nodes,
        snapshots: snapshots,
        drafts: drafts,
        revisions: revisions,
        specs: specs,
        candidates: candidates,
        selections: selections,
        stale_records: stale_records,
        timeline: timeline,
        renders: renders,
        attempts: attempts
      })

    stage = Map.get(socket.assigns, :stage, socket.assigns.live_action || :source)
    provider_mode = Application.fetch_env!(:dramatizer, :provider_mode)
    defaults = Application.fetch_env!(:dramatizer, :model_defaults)
    text_config = Map.fetch!(defaults, :people_relations)
    image_config = Map.fetch!(defaults, :reference_image)

    socket
    |> assign(:stage, stage)
    |> assign(:profile, Projects.effective_profile(socket.assigns.project))
    |> assign(:budget, Costs.get_budget(socket.assigns.project))
    |> assign(:provider_mode, provider_mode)
    |> assign(:credential_available, credential_available?(text_config.credential_ref))
    |> assign(:text_model, text_config.model)
    |> assign(:image_model, image_config.model)
    |> assign(:model_task_types, model_task_types())
    |> assign(:prompt_task_types, prompt_task_types())
    |> assign(:state, Map.fetch!(stage_states, stage))
    |> assign(:stage_states, stage_states)
    |> assign(:source_revisions, source_revisions)
    |> assign(:runs, runs)
    |> assign(:nodes, current_nodes(nodes, runs))
    |> assign(:analysis_snapshots, snapshots)
    |> assign(:episode_candidates, episode_candidates)
    |> assign(:drafts, drafts)
    |> assign(:revisions, revisions)
    |> assign(:specs, specs)
    |> assign(:assets, assets)
    |> assign(:selections, selections)
    |> assign(:stale_records, stale_records)
    |> assign(:candidates, candidates)
    |> assign(:reference_candidates, reference_candidates)
    |> assign(:shot_candidates, shot_candidates)
    |> assign(:reference_slots, reference_slots)
    |> assign(:reference_assets, reference_assets)
    |> assign(:timeline, timeline)
    |> assign(:clips, clips)
    |> assign(:subtitles, subtitles)
    |> assign(:renders, renders)
    |> assign(:attempts, attempts)
    |> assign(:costs, costs)
    |> assign(:change_sets, change_sets)
    |> assign(:revision_pairs, revision_pairs(revisions))
  end

  defp materialize_generation_specs(project, revision) do
    count = ConfigResolver.resolve(:shot_keyframe, project).params["candidate_count"] || 2

    if is_integer(count) and count > 0 do
      Enum.each(revision.payload["specs"], fn compiled ->
        payload =
          compiled
          |> Map.get("payload", %{})
          |> Map.put("shot_id", compiled["shot_id"])

        Enum.each(0..(count - 1), fn index ->
          {:ok, _spec} =
            Generation.create_spec(project, %{
              revision_id: revision.id,
              kind: compiled["kind"],
              candidate_index: index,
              formal: true,
              payload: payload
            })
        end)
      end)

      :ok
    else
      {:error, :invalid_candidate_count}
    end
  end

  defp materialize_reference_specs(project, visual) do
    config = ConfigResolver.resolve(:reference_image, project)
    count = config.params["candidate_count"] || 4
    {width, height} = parse_image_size(config.params["size"] || "768x1360")

    if is_integer(count) and count > 0 do
      specs =
        for object <- visual.payload["objects"] || [],
            object["reference_required"],
            variant <- object["variants"] || [],
            slot <- variant["required_slots"] || [],
            index <- 0..(count - 1) do
          reference_slot = "#{object["id"]}/#{variant["id"]}/#{slot}"

          payload = %{
            "object_id" => object["id"],
            "reference_slot" => reference_slot,
            "slot_key" => "reference:#{reference_slot}",
            "object" => object,
            "variant" => variant,
            "slot" => slot,
            "prompt" => "为#{object["name"] || object["id"]}生成#{slot}参考图",
            "width" => width,
            "height" => height,
            "aspect_width" => visual.profile_snapshot["aspect_width"] || 9,
            "aspect_height" => visual.profile_snapshot["aspect_height"] || 16,
            "aspect_tolerance" => 0.01,
            "dependencies" => %{"visual_design_revision_id" => visual.id}
          }

          {:ok, spec} =
            Generation.create_spec(project, %{
              revision_id: visual.id,
              kind: "reference_image",
              candidate_index: index,
              formal: true,
              payload: payload
            })

          spec
        end

      {:ok, specs}
    else
      {:error, :invalid_candidate_count}
    end
  end

  defp shot_selections(selections),
    do: Enum.filter(selections, &String.starts_with?(&1.slot_key, "shot:"))

  defp fake_fault_spec(project) do
    Generation.create_spec(project, %{
      kind: "recovery_probe",
      candidate_index: 0,
      formal: false,
      payload: %{
        "shot_id" => "RECOVERY",
        "width" => 270,
        "height" => 480,
        "aspect_width" => 9,
        "aspect_height" => 16,
        "prompt" => "Fake recovery probe"
      }
    })
  end

  defp fake_fault_profile do
    %{
      fail_on_attempt: 1,
      duplicate_callbacks: 3,
      out_of_order_callbacks: true,
      cost_micros: 23
    }
  end

  defp attempt_traces(project_id) do
    Repo.all(
      from attempt in Attempt,
        join: request in ProviderRequestSnapshot,
        on: request.id == attempt.provider_request_snapshot_id,
        join: spec in GenerationSpec,
        on: spec.id == request.generation_spec_id,
        where: spec.project_id == ^project_id,
        order_by: [desc: attempt.inserted_at],
        select: %{
          id: attempt.id,
          status: attempt.status,
          attempt_number: attempt.attempt_number,
          error_code: attempt.error_code,
          task_type: request.task_type,
          adapter: request.adapter,
          model: request.model,
          spec_id: spec.id
        }
    )
  end

  defp build_candidates(assets, specs, reports, selections, attempts, costs) do
    specs_by_id = Map.new(specs, &{&1.id, &1})
    assets_by_id = Map.new(assets, &{&1.id, &1})
    selected_ids = MapSet.new(selections, & &1.asset_version_id)

    reports_by_asset =
      Enum.reduce(reports, %{}, fn report, acc ->
        Map.update(
          acc,
          report.asset_version_id,
          %{report.kind => report},
          &Map.put_new(&1, report.kind, report)
        )
      end)

    assets
    |> Enum.filter(&String.starts_with?(&1.mime_type, "image/"))
    |> Enum.flat_map(fn asset ->
      spec_id = asset.lineage["generation_spec_id"]

      case Map.get(specs_by_id, spec_id) do
        nil ->
          []

        spec ->
          asset_reports = Map.get(reports_by_asset, asset.id, %{})
          technical = Map.get(asset_reports, :technical)
          semantic = Map.get(asset_reports, :semantic)
          shot_id = spec.payload["shot_id"] || spec.payload["object_id"] || "reference"
          spec_attempts = Enum.filter(attempts, &(&1.spec_id == spec.id))
          attempt_ids = MapSet.new(spec_attempts, & &1.id)

          actual_costs =
            Enum.filter(
              costs,
              &(&1.entry_type == :actual and MapSet.member?(attempt_ids, &1.attempt_id))
            )

          cost_micros =
            if actual_costs != [] and Enum.all?(actual_costs, &is_integer(&1.amount_micros)) do
              Enum.reduce(actual_costs, 0, &(&1.amount_micros + &2))
            end

          reference_ids =
            spec.payload["reference_asset_ids"] ||
              get_in(spec.payload, ["links", "reference_asset_ids"]) || []

          reference_urls =
            reference_ids
            |> Enum.filter(&Map.has_key?(assets_by_id, &1))
            |> Enum.map(&"/media/#{&1}")

          [
            %{
              asset: asset,
              image_url: "/media/#{asset.id}",
              spec_id: spec.id,
              spec_kind: spec.kind,
              index: spec.candidate_index,
              slot_key: candidate_slot_key(spec, shot_id),
              summary: candidate_summary(spec.payload),
              technical: technical && technical.status,
              semantic: semantic && semantic.status,
              semantic_evidence: get_in(semantic && semantic.evidence, ["dimensions"]) || %{},
              reference_urls: reference_urls,
              attempts: spec_attempts,
              cost_micros: cost_micros,
              formal: spec.formal,
              selected: MapSet.member?(selected_ids, asset.id)
            }
          ]
      end
    end)
    |> Enum.sort_by(&{&1.slot_key, &1.index})
  end

  defp candidate_summary(payload) do
    value = payload["positive_prompt"] || payload["prompt"] || payload["shot_id"] || "结构化生成规格"
    value |> to_string() |> String.slice(0, 140)
  end

  defp candidate_slot_key(spec, shot_id) do
    spec.payload["slot_key"] ||
      if(spec.kind == "reference_image",
        do: "reference:#{spec.payload["reference_slot"] || shot_id}",
        else: "shot:#{shot_id}"
      )
  end

  defp parse_image_size(value) do
    case String.split(to_string(value), "x", parts: 2) do
      [width, height] -> {String.to_integer(width), String.to_integer(height)}
      _ -> {768, 1360}
    end
  rescue
    ArgumentError -> {768, 1360}
  end

  defp episode_candidates([snapshot | _]) do
    snapshot.node_results
    |> Map.values()
    |> Enum.flat_map(&(get_in(&1, ["output", "items"]) || []))
    |> Enum.filter(&(&1["kind"] == "episode"))
  end

  defp episode_candidates([]), do: []

  defp reference_slots(revisions) do
    case latest_revision(revisions, :visual_design) do
      nil ->
        []

      revision ->
        for object <- revision.payload["objects"] || [],
            object["reference_required"],
            variant <- object["variants"] || [],
            slot <- variant["required_slots"] || [] do
          "#{object["id"]}/#{variant["id"]}/#{slot}"
        end
    end
  end

  defp revision_pairs(revisions) do
    revisions
    |> Enum.group_by(& &1.logical_id)
    |> Enum.flat_map(fn {_logical_id, values} ->
      values
      |> Enum.sort_by(& &1.revision)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [old_revision, new_revision] -> {old_revision, new_revision} end)
    end)
  end

  defp current_nodes(nodes, [run | _]), do: Enum.filter(nodes, &(&1.workflow_run_id == run.id))
  defp current_nodes(_nodes, []), do: []

  defp stage_states(data) do
    stale? = data.stale_records != []
    narrative? = Enum.any?(data.revisions, &(&1.kind == :narrative))
    visual? = Enum.any?(data.revisions, &(&1.kind == :visual_design))
    shot_plan? = Enum.any?(data.revisions, &(&1.kind == :shot_plan))

    %{
      source: if(data.source_revisions == [], do: :empty, else: :ready),
      analysis: analysis_state(data),
      episodes:
        cond do
          stale? -> :stale
          narrative? -> :ready
          data.snapshots != [] -> :waiting_user
          true -> :waiting_user
        end,
      visuals:
        cond do
          stale? -> :stale
          visual? -> :ready
          narrative? -> :waiting_user
          true -> :waiting_user
        end,
      shots:
        cond do
          stale? -> :stale
          shot_plan? and data.candidates != [] and data.selections != [] -> :ready
          Enum.any?(data.attempts, &(&1.status in [:failed, :timed_out])) -> :failed
          Enum.any?(data.attempts, &(&1.status in [:prepared, :submitted])) -> :loading
          true -> :waiting_user
        end,
      timeline:
        cond do
          stale? ->
            :stale

          Enum.any?(data.renders, &(&1.status == :failed)) ->
            :failed

          Enum.any?(data.renders, &(&1.status == :rendering)) ->
            :loading

          Enum.any?(data.renders, &(&1.status == :rendered and &1.render_mode == :formal)) ->
            :ready

          data.timeline ->
            :waiting_user

          true ->
            :waiting_user
        end,
      runs: runs_state(data)
    }
  end

  defp analysis_state(%{source_revisions: []}), do: :waiting_user

  defp analysis_state(data) do
    cond do
      Enum.any?(data.nodes, &(&1.status == :failed)) -> :failed
      Enum.any?(data.nodes, &(&1.status in [:queued, :running])) -> :loading
      data.snapshots != [] -> :ready
      true -> :waiting_user
    end
  end

  defp runs_state(data) do
    cond do
      data.runs == [] and data.attempts == [] ->
        :empty

      Enum.any?(data.nodes, &(&1.status == :failed)) or
          Enum.any?(data.attempts, &(&1.status in [:failed, :timed_out])) ->
        :failed

      Enum.any?(data.nodes, &(&1.status in [:queued, :running])) or
          Enum.any?(data.attempts, &(&1.status in [:prepared, :submitted])) ->
        :loading

      true ->
        :ready
    end
  end

  defp latest_revision(revisions, kind), do: Enum.find(revisions, &(&1.kind == kind))
  defp drafts_for(drafts, kind), do: Enum.filter(drafts, &(&1.kind == kind))

  defp draft_form(draft) do
    to_form(%{"payload" => Jason.encode!(draft.payload, pretty: true)}, as: :draft)
  end

  defp visual_form do
    objects = [
      %{
        "id" => "character:lead",
        "type" => "character",
        "name" => "主角",
        "recurring" => true,
        "variants" => [%{"id" => "default"}]
      },
      %{
        "id" => "location:main",
        "type" => "location",
        "name" => "主场景",
        "key" => true,
        "variants" => [%{"id" => "default"}]
      }
    ]

    to_form(%{"objects" => Jason.encode!(objects, pretty: true)}, as: :visual)
  end

  defp shot_form do
    proposal = %{
      "scenes" => [%{"id" => "SC001", "name" => "主场景"}],
      "shots" => [
        %{
          "id" => "S001",
          "scene_id" => "SC001",
          "description" => "雨夜车站建立环境与人物关系",
          "minimum_duration_ms" => 1_500,
          "preferred_duration_ms" => 2_000,
          "maximum_duration_ms" => 2_800,
          "camera" => "push_in"
        },
        %{
          "id" => "S002",
          "scene_id" => "SC001",
          "description" => "林夏发现匿名信上的异常细节",
          "minimum_duration_ms" => 1_400,
          "preferred_duration_ms" => 1_800,
          "maximum_duration_ms" => 2_500,
          "camera" => "pan_left"
        },
        %{
          "id" => "S003",
          "scene_id" => "SC001",
          "description" => "林夏抬头确认寄信人仍在附近",
          "minimum_duration_ms" => 1_300,
          "preferred_duration_ms" => 1_700,
          "maximum_duration_ms" => 2_300,
          "camera" => "pull_out"
        }
      ]
    }

    to_form(%{"proposal" => Jason.encode!(proposal, pretty: true)}, as: :shot)
  end

  defp result_flash(socket, {:ok, _value}, message), do: put_flash(socket, :info, message)

  defp result_flash(socket, {:error, reason}, _message),
    do: put_flash(socket, :error, human_error(reason))

  defp result_flash(socket, other, _message), do: put_flash(socket, :error, human_error(other))

  defp human_error({:unresolved_stale, _ids}), do: "仍有未解决的过期选择，需先固定旧输入或替换。"
  defp human_error(:confirmed_timeline_inputs_required), do: "请先确认 Narrative 与 ShotPlan。"
  defp human_error(:analysis_snapshot_required), do: "请先完成全文分析。"
  defp human_error(:invalid_json), do: "JSON 格式无效。"
  defp human_error(:invalid_candidate_count), do: "候选数量必须是正整数。"
  defp human_error(:shot_selection_required), do: "时间线只能使用镜头候选，不能使用参考图。"
  defp human_error(reason), do: inspect(reason)

  defp upload_unready?([]), do: true
  defp upload_unready?(entries), do: Enum.any?(entries, &(&1.progress < 100))

  defp parse_positive_integer(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :positive_integer_required}
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} when number >= 0 -> {:ok, number}
      _ -> {:error, :non_negative_integer_required}
    end
  end

  defp parse_motion(value) do
    case value do
      "static" -> {:ok, :static}
      "push_in" -> {:ok, :push_in}
      "pull_out" -> {:ok, :pull_out}
      "pan_left" -> {:ok, :pan_left}
      "pan_right" -> {:ok, :pan_right}
      "pan_up" -> {:ok, :pan_up}
      "pan_down" -> {:ok, :pan_down}
      _ -> {:error, :invalid_motion}
    end
  end

  defp parse_transition("hard_cut"), do: {:ok, :hard_cut}
  defp parse_transition("cross_dissolve"), do: {:ok, :cross_dissolve}
  defp parse_transition(_value), do: {:error, :invalid_transition}

  defp model_task_types do
    :dramatizer
    |> Application.fetch_env!(:model_defaults)
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(&Atom.to_string/1)
  end

  defp prompt_task_types, do: Catalog.task_types() |> Enum.map(&Atom.to_string/1)

  defp model_task_type(value) do
    Enum.find_value(model_task_types(), {:error, :unknown_model_task_type}, fn task ->
      if task == value, do: {:ok, String.to_existing_atom(task)}
    end)
  end

  defp prompt_task_type(value) do
    Enum.find_value(prompt_task_types(), {:error, :unknown_prompt_task_type}, fn task ->
      if task == value, do: {:ok, String.to_existing_atom(task)}
    end)
  end

  defp parse_budget_micros(value, project) do
    case Decimal.parse(value) do
      {decimal, ""} ->
        micros = decimal |> Decimal.mult(1_000_000) |> Decimal.round(0) |> Decimal.to_integer()

        if micros >= 0 do
          Costs.set_budget(project, micros)
        else
          {:error, :invalid_budget}
        end

      _ ->
        {:error, :invalid_budget}
    end
  end

  defp credential_available?(reference) do
    case System.get_env(reference) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp node_state(status) when status in [:queued, :running], do: :loading
  defp node_state(:failed), do: :failed
  defp node_state(:succeeded), do: :ready
  defp node_state(_), do: :empty

  defp node_label("people_relations"), do: "人物与关系"
  defp node_label("places_props_world"), do: "场景、道具与世界"
  defp node_label("events_timeline"), do: "事件时间线"
  defp node_label("entity_merge"), do: "实体归并"
  defp node_label("episode_candidates"), do: "分集候选"
  defp node_label("conflict_check"), do: "冲突检查"
  defp node_label(value), do: value

  defp stage_code(stage),
    do:
      "STAGE " <>
        ((Enum.find_index(@stages, &(&1 == stage)) + 1)
         |> Integer.to_string()
         |> String.pad_leading(2, "0"))

  defp stage_title(:source), do: "原著导入"
  defp stage_title(:analysis), do: "全文解析"
  defp stage_title(:episodes), do: "分集与 Narrative"
  defp stage_title(:visuals), do: "视觉权威与参考集"
  defp stage_title(:shots), do: "镜头生产与裁决"
  defp stage_title(:timeline), do: "剪辑、字幕与导出"
  defp stage_title(:runs), do: "运行、错误与成本"

  defp stage_description(:source), do: "全文保真进入系统，文件格式差异由 parser 收敛。"
  defp stage_description(:analysis), do: "独立节点提取事实，失败可局部修复，不重跑已成功节点。"
  defp stage_description(:episodes), do: "AI 提议候选，人明确选择、编辑并冻结叙事权威。"
  defp stage_description(:visuals), do: "先确定角色、场景与道具，再管理参考图主版本。"
  defp stage_description(:shots), do: "比较生成规格、逐维 QC、尝试与成本后，由人选择每个镜头。"
  defp stage_description(:timeline), do: "编辑镜头节奏与字幕；预览可变，正式导出依赖冻结版本。"
  defp stage_description(:runs), do: "检查每次执行的模型、错误、恢复动作和真实成本。"

  defp kind_label(:narrative), do: "Narrative"
  defp kind_label(:visual_design), do: "VisualDesign"
  defp kind_label(:shot_plan), do: "ShotPlan"
  defp kind_label(kind), do: Atom.to_string(kind)
end
