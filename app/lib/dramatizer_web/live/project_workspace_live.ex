defmodule DramatizerWeb.ProjectWorkspaceLive do
  use DramatizerWeb, :live_view

  import Ecto.Query

  alias Dramatizer.Analysis.AnalysisSnapshot
  alias Dramatizer.Analysis
  alias Dramatizer.Analysis.DAG
  alias Dramatizer.Assets
  alias Dramatizer.Assets.AssetVersion
  alias Dramatizer.Changes
  alias Dramatizer.Changes.{ChangeSet, StaleRecord}
  alias Dramatizer.Costs
  alias Dramatizer.Costs.CostEntry
  alias Dramatizer.Directing
  alias Dramatizer.Directing.Compiler
  alias Dramatizer.Execution.WorkerRegistry
  alias Dramatizer.Generation

  alias Dramatizer.Generation.{
    Attempt,
    ConfigResolver,
    GenerationSpec,
    ProviderRequestSnapshot
  }

  alias Dramatizer.Narrative
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
  alias Dramatizer.Workflow.Enqueue
  alias Dramatizer.Workflow.{NodeRun, WorkflowRun}

  alias DramatizerWeb.Forms.{
    ModelOverrideForm,
    NarrativeDraftForm,
    ShotPlanDraftForm,
    VisualDesignDraftForm
  }

  alias DramatizerWeb.ProjectWorkspace.Subscription

  alias DramatizerWeb.Live.Components.{
    AnalysisReview,
    CandidateGallery,
    ChangeImpact,
    GenerationSpecReview,
    NarrativeEditor,
    ProjectSettings,
    ProviderStatus,
    RunPanel,
    StageNav,
    TimelineEditor,
    ReferenceMatrix,
    ShotPlanEditor,
    VisualDesignEditor
  }

  @stages ~w(source analysis episodes visuals shots timeline runs)a
  @image_extensions ~w(.png .jpg .jpeg .webp)

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_project!(id)

    if connected?(socket), do: :ok = Subscription.subscribe(project)

    socket =
      socket
      |> assign(:project, project)
      |> assign(:page_title, project.name)
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
            nil ->
              revisions = source_revisions(socket.assigns.project.id)

              case Analysis.enqueue(
                     socket.assigns.project,
                     Enum.map(revisions, & &1.id)
                   ) do
                {:ok, _run} ->
                  socket
                  |> put_flash(:info, "原著已解析，全文分析已加入队列。")
                  |> push_patch(to: ~p"/projects/#{socket.assigns.project.id}/analysis")

                {:error, reason} ->
                  socket
                  |> put_flash(:error, human_error(reason))
                  |> load_workspace()
              end

            {:error, reason} ->
              put_flash(socket, :error, human_error(reason))
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
      case Analysis.enqueue(socket.assigns.project, revision_ids) do
        {:ok, _run} ->
          socket
          |> put_flash(:info, "全文分析已加入队列。")
          |> load_workspace()

        {:error, reason} ->
          put_flash(socket, :error, human_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("retry-node", %{"id" => id}, socket) do
    result = id |> then(&Repo.get!(NodeRun, &1)) |> Analysis.retry_node()
    {:noreply, result_flash(socket, result, "节点已重新排队。") |> load_workspace()}
  end

  def handle_event("select-episode", %{"candidate-id" => candidate_id}, socket) do
    snapshot = List.first(socket.assigns.analysis_snapshots)

    result =
      if snapshot do
        with {:ok, authority} <- Narrative.proposal_authority(snapshot, candidate_id),
             {:ok, run} <-
               Generation.enqueue_proposal(
                 socket.assigns.project,
                 :narrative_proposal,
                 authority,
                 materialization: %{
                   kind: :narrative,
                   analysis_snapshot_id: snapshot.id,
                   candidate_id: candidate_id
                 }
               ) do
          {:ok, run}
        end
      else
        {:error, :analysis_snapshot_required}
      end

    {:noreply, result_flash(socket, result, "Narrative 提案已加入队列。") |> load_workspace()}
  end

  def handle_event("save-narrative-draft", %{"id" => id, "narrative" => params}, socket) do
    draft = Repo.get!(Draft, id)

    result =
      with :narrative <- draft.kind,
           {:ok, payload} <- NarrativeDraftForm.cast(params, draft.payload) do
        Revisions.replace_draft_payload(draft, payload)
      else
        {:error, errors} -> {:error, {:form_validation, errors}}
        _other -> {:error, :invalid_narrative_draft}
      end

    {:noreply, result_flash(socket, result, "Narrative Draft 已保存。") |> load_workspace()}
  end

  def handle_event("add-narrative-item", %{"id" => id, "collection" => collection}, socket) do
    mutate_narrative_draft(socket, id, fn payload ->
      NarrativeDraftForm.add(payload, collection, narrative_item(collection))
    end)
  end

  def handle_event(
        "remove-narrative-item",
        %{"id" => id, "collection" => collection, "item-id" => item_id},
        socket
      ) do
    mutate_narrative_draft(socket, id, fn payload ->
      NarrativeDraftForm.remove(payload, collection, item_id)
    end)
  end

  def handle_event(
        "move-narrative-item",
        %{
          "id" => id,
          "collection" => collection,
          "item-id" => item_id,
          "direction" => direction
        },
        socket
      ) do
    parsed_direction = if direction == "up", do: :up, else: :down

    mutate_narrative_draft(socket, id, fn payload ->
      NarrativeDraftForm.move(payload, collection, item_id, parsed_direction)
    end)
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
    socket =
      case Revisions.confirm_draft(id) do
        {:ok, %Revision{kind: :narrative} = narrative} ->
          case create_visual_proposal(socket.assigns.project, narrative) do
            {:ok, _run} ->
              put_flash(socket, :info, "Narrative 已冻结，VisualDesign 提案已加入队列。")

            {:error, reason} ->
              put_flash(
                socket,
                :error,
                "Narrative 已冻结，但 VisualDesign 提案入队失败：#{human_error(reason)}"
              )
          end

        {:ok, %Revision{kind: :reference_set} = reference_set} ->
          case create_directing_proposal(socket, reference_set) do
            {:ok, _run} ->
              put_flash(socket, :info, "ReferenceSet 已冻结，Directing 提案已加入队列。")

            {:error, reason} ->
              put_flash(
                socket,
                :error,
                "ReferenceSet 已冻结，但 Directing 提案入队失败：#{human_error(reason)}"
              )
          end

        {:ok, _revision} ->
          put_flash(socket, :info, "已冻结为不可变 Revision。")

        {:error, reason} ->
          put_flash(socket, :error, human_error(reason))
      end

    {:noreply, load_workspace(socket)}
  end

  def handle_event("save-shot-plan-draft", %{"id" => id, "shot_plan" => params}, socket) do
    draft = Repo.get!(Draft, id)

    result =
      with :shot_plan <- draft.kind,
           {:ok, payload} <- ShotPlanDraftForm.cast(params, draft.payload) do
        Revisions.replace_draft_payload(draft, payload)
      else
        {:error, errors} -> {:error, {:form_validation, errors}}
        _other -> {:error, :invalid_shot_plan}
      end

    {:noreply, result_flash(socket, result, "ShotPlan Draft 已保存。") |> load_workspace()}
  end

  def handle_event(
        "add-shot-item",
        %{"id" => id, "collection" => collection} = params,
        socket
      ) do
    mutate_shot_draft(socket, id, fn payload ->
      ShotPlanDraftForm.add(
        payload,
        collection,
        shot_item(collection, Map.get(params, "scene-id"))
      )
    end)
  end

  def handle_event(
        "remove-shot-item",
        %{"id" => id, "collection" => collection, "item-id" => item_id},
        socket
      ) do
    mutate_shot_draft(socket, id, fn payload ->
      ShotPlanDraftForm.remove(payload, collection, item_id)
    end)
  end

  def handle_event(
        "move-shot-item",
        %{
          "id" => id,
          "collection" => collection,
          "item-id" => item_id,
          "direction" => direction
        },
        socket
      ) do
    parsed_direction = if direction == "up", do: :up, else: :down

    mutate_shot_draft(socket, id, fn payload ->
      ShotPlanDraftForm.move(payload, collection, item_id, parsed_direction)
    end)
  end

  def handle_event("save-visual-design-draft", %{"id" => id, "visual_design" => params}, socket) do
    draft = Repo.get!(Draft, id)

    result =
      with :visual_design <- draft.kind,
           {:ok, payload} <- VisualDesignDraftForm.cast(params, draft.payload) do
        Revisions.replace_draft_payload(draft, payload)
      else
        {:error, errors} -> {:error, {:form_validation, errors}}
        _other -> {:error, :invalid_visual_design}
      end

    {:noreply, result_flash(socket, result, "VisualDesign Draft 已保存。") |> load_workspace()}
  end

  def handle_event(
        "add-visual-item",
        %{"id" => id, "collection" => collection} = params,
        socket
      ) do
    mutate_visual_draft(socket, id, fn payload ->
      type = visual_collection_type(payload, collection, Map.get(params, "type"))

      VisualDesignDraftForm.add(
        payload,
        collection,
        visual_item(collection, type)
      )
    end)
  end

  def handle_event(
        "remove-visual-item",
        %{"id" => id, "collection" => collection, "item-id" => item_id},
        socket
      ) do
    mutate_visual_draft(socket, id, fn payload ->
      VisualDesignDraftForm.remove(payload, collection, item_id)
    end)
  end

  def handle_event(
        "move-visual-item",
        %{
          "id" => id,
          "collection" => collection,
          "item-id" => item_id,
          "direction" => direction
        },
        socket
      ) do
    parsed_direction = if direction == "up", do: :up, else: :down

    mutate_visual_draft(socket, id, fn payload ->
      VisualDesignDraftForm.move(payload, collection, item_id, parsed_direction)
    end)
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
        enqueue_specs(socket.assigns.project, specs, :reference_image)
      else
        nil -> {:error, :confirmed_visual_design_required}
        error -> error
      end

    {:noreply,
     result_flash(socket, result, "参考图候选已加入队列。")
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
           {:ok, run} <-
             Generation.enqueue_pipeline(
               socket.assigns.project,
               spec,
               :image_edit,
               reference_asset_ids: [parent.id]
             ) do
        {:ok, run}
      else
        true -> {:error, :edit_instruction_required}
        error -> error
      end

    {:noreply, result_flash(socket, result, "图像编辑已加入队列。") |> load_workspace()}
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

    result = enqueue_specs(socket.assigns.project, specs, :shot_keyframe)

    {:noreply, result_flash(socket, result, "镜头候选已加入队列。") |> load_workspace()}
  end

  def handle_event("inject-fake-failure", _params, socket) do
    {:ok, spec} = fake_fault_spec(socket.assigns.project)

    result =
      Generation.enqueue_pipeline(socket.assigns.project, spec, :shot_keyframe,
        fault_profile: fake_fault_profile()
      )

    {:noreply, result_flash(socket, result, "Fake 故障探针已加入队列。") |> load_workspace()}
  end

  def handle_event("resume-fake-failure", _params, socket) do
    {:ok, spec} = fake_fault_spec(socket.assigns.project)

    result =
      retry_generation_pipeline(socket.assigns.project, spec, :shot_keyframe,
        fault_profile: fake_fault_profile()
      )

    {:noreply,
     result_flash(socket, result, "Fake 故障节点已重新排队。")
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

  def handle_event(
        "confirm-change",
        %{"change" => %{"present" => "true"} = params},
        %{assigns: %{impact: impact}} = socket
      )
      when not is_nil(impact) do
    selected_ids = Map.get(params, "target_ids", [])
    result = Changes.confirm(impact, selected_ids)

    {:noreply,
     socket
     |> assign(:impact, nil)
     |> result_flash(result, "ChangeSet 所选影响范围已确认。")
     |> load_workspace()}
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

  def handle_event(
        "select-candidate-with-note",
        %{
          "asset-id" => asset_id,
          "spec-id" => spec_id,
          "slot-key" => slot_key,
          "selection" => %{"note" => note}
        },
        socket
      ) do
    result =
      Quality.select(
        socket.assigns.project,
        slot_key,
        Repo.get!(GenerationSpec, spec_id),
        Repo.get!(AssetVersion, asset_id),
        note: String.trim(note)
      )

    {:noreply, result_flash(socket, result, "候选与验收备注已保存。") |> load_workspace()}
  end

  def handle_event("regenerate-candidate", %{"spec-id" => spec_id}, socket) do
    parent = Repo.get!(GenerationSpec, spec_id)

    next_index =
      (Repo.one(
         from spec in GenerationSpec,
           where:
             spec.project_id == ^parent.project_id and spec.kind == ^parent.kind and
               spec.payload_hash == ^parent.payload_hash and spec.formal == ^parent.formal,
           select: max(spec.candidate_index)
       ) || -1) + 1

    result =
      with {:ok, spec} <-
             Generation.create_spec(socket.assigns.project, %{
               revision_id: parent.revision_id,
               kind: parent.kind,
               candidate_index: next_index,
               formal: parent.formal,
               payload: parent.payload
             }),
           {:ok, task_type} <- generation_task_type(parent.kind) do
        Generation.enqueue_pipeline(socket.assigns.project, spec, task_type)
      end

    {:noreply, result_flash(socket, result, "新候选已加入队列。") |> load_workspace()}
  end

  def handle_event("resolve-stale", %{"selection-id" => id}, socket) do
    result = id |> Repo.get!(SelectionDecision) |> Changes.resolve_stale(:pin_old_input)
    {:noreply, result_flash(socket, result, "已固定旧输入闭包。") |> load_workspace()}
  end

  def handle_event(
        "resolve-stale-replace",
        %{"selection-id" => id, "replacement" => %{"asset_id" => asset_id}},
        socket
      ) do
    result = id |> Repo.get!(SelectionDecision) |> Changes.resolve_stale({:replace, asset_id})
    {:noreply, result_flash(socket, result, "已用新候选替换过期主图。") |> load_workspace()}
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
        TimelineContext.enqueue_render(manifest)
      else
        nil -> {:error, :timeline_required}
        error -> error
      end

    {:noreply, result_flash(socket, result, "预览渲染已加入队列。") |> load_workspace()}
  end

  def handle_event("freeze-timeline", _params, socket) do
    result =
      with %TimelineRecord{} = timeline <- socket.assigns.timeline,
           {:ok, version} <- TimelineContext.freeze(timeline),
           {:ok, manifest} <- RenderRecipe.formal(version) do
        TimelineContext.enqueue_render(manifest)
      else
        nil -> {:error, :timeline_required}
        error -> error
      end

    {:noreply, result_flash(socket, result, "正式渲染已加入队列。") |> load_workspace()}
  end

  @impl Phoenix.LiveView
  def handle_info({:execution_changed, event}, socket) do
    socket =
      if event[:project_id] == socket.assigns.project.id do
        reload_execution_slice(socket, Subscription.slice_for(event))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

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

        <div class="workspace-layout">
          <StageNav.stage_nav project={@project} current={@stage} states={@stage_states} />

          <main
            class="workspace-main"
            data-workspace-canvas
            data-stage={@stage}
            data-state={@state}
          >
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
                  phx-disable-with="正在入队…"
                  disabled={
                    @source_revisions == [] or
                      analysis_workflow_active?(@runs, @project, @provider_mode)
                  }
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
                    :if={node.status == :failed and node.error_code != "unknown_remote_state"}
                    type="button"
                    class="btn btn-ghost"
                    phx-click="retry-node"
                    phx-value-id={node.id}
                    phx-disable-with="正在重新排队…"
                  >
                    仅重试本节点
                  </button>
                </article>
              </div>
              <AnalysisReview.analysis_review snapshot={List.first(@analysis_snapshots)} />
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
                    phx-disable-with="正在入队…"
                    disabled={workflow_active?(@runs, "structured_proposal_v1")}
                  >
                    选择并创建 Narrative
                  </button>
                </article>
              </div>
              <NarrativeEditor.narrative_editor
                :for={draft <- drafts_for(@drafts, :narrative)}
                draft={draft}
              />
              <div
                :if={@episode_candidates == [] and drafts_for(@drafts, :narrative) == []}
                class="empty-panel compact"
              >
                全文分析完成后，请在此明确选择一个分集候选。
              </div>
            </section>

            <section :if={@stage == :visuals} class="workspace-panel" data-human-gate>
              <VisualDesignEditor.visual_design_editor
                :for={draft <- drafts_for(@drafts, :visual_design)}
                draft={draft}
              />
              <div :if={drafts_for(@drafts, :visual_design) == []} class="empty-panel">
                <h3>等待 Narrative 权威</h3>
                <p>确认 Narrative 后，系统会自动调用 AI 生成角色、场景、道具和 Variant 提案。</p>
              </div>
              <div class="visual-tool-row">
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
              <div :if={@reference_slots != []} class="panel-actions production-actions">
                <button
                  type="button"
                  class="btn btn-primary"
                  phx-click="generate-reference-candidates"
                  phx-disable-with="正在入队…"
                  disabled={generation_active?(@runs)}
                >
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
              <CandidateGallery.candidate_gallery
                candidates={@reference_candidates}
                upstream_path={~p"/projects/#{@project.id}/visuals"}
              />
              <ReferenceMatrix.reference_matrix
                slots={@reference_slots}
                candidates={@reference_candidates}
                assets={@reference_assets}
              />
              <.reference_set_editor
                :for={draft <- drafts_for(@drafts, :reference_set)}
                draft={draft}
              />
            </section>

            <section :if={@stage == :shots} class="workspace-panel" data-human-gate>
              <ShotPlanEditor.shot_plan_editor
                :for={draft <- drafts_for(@drafts, :shot_plan)}
                draft={draft}
              />
              <div :if={drafts_for(@drafts, :shot_plan) == []} class="empty-panel">
                <h3>等待 ReferenceSet 权威</h3>
                <p>确认主参考图集合后，系统会自动生成完整导演提案。</p>
              </div>
              <div class="panel-actions production-actions">
                <button type="button" class="btn btn-soft" phx-click="compile-shot-specs">
                  编译冻结 GenerationSpec
                </button>
                <button
                  type="button"
                  class="btn btn-primary"
                  phx-click="generate-shot-candidates"
                  phx-disable-with="正在入队…"
                  disabled={
                    Enum.all?(@specs, &(&1.kind != "shot_keyframe")) or
                      generation_active?(@runs)
                  }
                >
                  生成候选并执行 QC
                </button>
              </div>
              <GenerationSpecReview.generation_spec_review
                revision={latest_revision(@revisions, :generation_spec)}
                specs={@specs}
              />
              <CandidateGallery.candidate_gallery
                candidates={@shot_candidates}
                upstream_path={~p"/projects/#{@project.id}/shots"}
              />
              <div :for={stale <- @stale_records} class="stale-row recovery-card">
                <div>
                  <span class="eyebrow">STALE · {stale.subject_type}</span>
                  <strong>{stale_label(stale.reason)}</strong>
                  <p>{stale_guidance(stale.reason)}</p>
                </div>
                <button
                  :if={stale.subject_type == "selection_decision"}
                  type="button"
                  class="btn btn-ghost"
                  phx-click="resolve-stale"
                  phx-value-selection-id={stale.subject_id}
                >
                  固定旧输入
                </button>
                <form
                  :if={stale.subject_type == "selection_decision" and @shot_candidates != []}
                  phx-submit="resolve-stale-replace"
                  phx-value-selection-id={stale.subject_id}
                  class="stale-replacement"
                >
                  <select name="replacement[asset_id]">
                    <option :for={candidate <- @shot_candidates} value={candidate.asset.id}>
                      {candidate.slot_key} · 候选 {candidate.index + 1}
                    </option>
                  </select>
                  <button type="submit" class="btn btn-soft">替换为新候选</button>
                </form>
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
                  <button
                    type="button"
                    class="btn btn-soft"
                    phx-click="inject-fake-failure"
                    phx-disable-with="正在入队…"
                  >
                    注入一次 Fake 失败
                  </button>
                  <button
                    type="button"
                    class="btn btn-primary"
                    phx-click="resume-fake-failure"
                    phx-disable-with="正在重新排队…"
                  >
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
              <ChangeImpact.change_impact impact={@impact} />
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

            <nav class="next-action-bar" data-next-action aria-label="下一步">
              <div>
                <span class="eyebrow">NEXT ACTION</span>
                <strong>{next_action_label(@stage)}</strong>
              </div>
              <.link navigate={stage_path(@project.id, next_stage(@stage))} class="btn btn-primary">
                {next_action_button(@stage)} <span aria-hidden="true">→</span>
              </.link>
            </nav>
          </main>

          <aside class="workspace-inspector" data-inspector aria-label="制作上下文">
            <div class="inspector-heading">
              <div>
                <span>CONTEXT</span>
                <strong>制作上下文</strong>
              </div>
              <button
                type="button"
                class="inspector-toggle"
                data-inspector-toggle
                aria-label="收起或展开制作上下文"
                aria-expanded="true"
              >
                <span aria-hidden="true">↔</span>
              </button>
            </div>
            <dl class="inspector-facts">
              <div>
                <dt>当前阶段</dt>
                <dd>{stage_title(@stage)}</dd>
              </div>
              <div>
                <dt>阶段状态</dt>
                <dd><.state_badge state={@state} /></dd>
              </div>
              <div>
                <dt>来源版本</dt>
                <dd>{length(@source_revisions)}</dd>
              </div>
              <div>
                <dt>编辑草稿</dt>
                <dd>{length(@drafts)}</dd>
              </div>
              <div>
                <dt>冻结版本</dt>
                <dd>{length(@revisions)}</dd>
              </div>
              <div>
                <dt>模型尝试</dt>
                <dd>{length(@attempts)}</dd>
              </div>
            </dl>
            <p class="inspector-note">
              表单保存 Draft；确认后生成不可变 Revision。上游变化会显式标记影响范围。
            </p>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :draft, :map, required: true

  defp reference_set_editor(assigns) do
    assigns =
      assigns
      |> assign(:required_count, length(assigns.draft.payload["required_slots"] || []))
      |> assign(:selected_count, map_size(assigns.draft.payload["primary_assets"] || %{}))

    ~H"""
    <article class="authority-editor reference-set-editor">
      <div class="section-heading compact">
        <div>
          <p class="eyebrow">REFERENCE SET AUTHORITY</p>
          <h3>主参考图集合</h3>
          <p>每个必需槽位都明确绑定一个不可变 AssetVersion。</p>
        </div>
        <.state_badge state={if @draft.status == :confirmed, do: :ready, else: :waiting_user} />
      </div>
      <div class="confirmed-authority-summary">
        <div><span>必需槽位</span><strong>{@required_count}</strong></div>
        <div><span>已选择</span><strong>{@selected_count}</strong></div>
        <div>
          <span>完整度</span><strong>{if @required_count == @selected_count, do: "完整", else: "待补充"}</strong>
        </div>
      </div>
      <div class="form-actions">
        <button
          :if={@draft.status == :editing}
          type="button"
          class="btn btn-primary"
          phx-click="confirm-draft"
          phx-value-id={@draft.id}
          phx-disable-with="正在确认并入队…"
        >
          确认并冻结 Revision
        </button>
        <button
          :if={@draft.status == :confirmed and @draft.confirmed_revision_id}
          type="button"
          class="btn btn-ghost"
          phx-click="derive-draft"
          phx-value-revision-id={@draft.confirmed_revision_id}
        >
          从此 Revision 派生修改
        </button>
      </div>
    </article>
    """
  end

  defp create_visual_proposal(project, narrative) do
    with {:ok, authority} <- Visuals.proposal_authority(narrative) do
      Generation.enqueue_proposal(project, :visual_design_proposal, authority,
        materialization: %{
          kind: :visual_design,
          narrative_revision_id: narrative.id
        }
      )
    end
  end

  defp create_directing_proposal(socket, reference_set) do
    narrative = latest_revision(socket.assigns.revisions, :narrative)
    visual_design = latest_revision(socket.assigns.revisions, :visual_design)

    with %Revision{} = narrative <- narrative,
         %Revision{} = visual_design <- visual_design,
         {:ok, authority} <-
           Directing.proposal_authority(narrative, visual_design, reference_set),
         {:ok, run} <-
           Generation.enqueue_proposal(
             socket.assigns.project,
             :directing_proposal,
             authority,
             materialization: %{
               kind: :directing,
               narrative_revision_id: narrative.id,
               visual_design_revision_id: visual_design.id,
               reference_set_revision_id: reference_set.id
             }
           ) do
      {:ok, run}
    else
      nil -> {:error, :confirmed_production_revisions_required}
      error -> error
    end
  end

  defp mutate_shot_draft(socket, draft_id, mutation) do
    draft = Repo.get!(Draft, draft_id)
    changed = mutation.(draft.payload)

    result =
      with :shot_plan <- draft.kind,
           {:ok, payload} <-
             ShotPlanDraftForm.cast(ShotPlanDraftForm.from_payload(changed), draft.payload) do
        Revisions.replace_draft_payload(draft, payload)
      else
        {:error, errors} -> {:error, {:form_validation, errors}}
        _other -> {:error, :invalid_shot_plan}
      end

    {:noreply, result_flash(socket, result, "ShotPlan Draft 已更新。") |> load_workspace()}
  end

  defp shot_item("scenes", _scene_id) do
    %{"id" => generated_id("SC"), "name" => "新场景", "purpose" => "待补充"}
  end

  defp shot_item("shots", scene_id) do
    %{
      "id" => generated_id("SH"),
      "scene_id" => scene_id || "",
      "beat_id" => "",
      "story_event_ids" => [],
      "presentation_goal" => "待补充呈现目标",
      "description" => "待补充镜头动作",
      "shot_class" => "MEDIUM",
      "coverage" => "primary",
      "minimum_duration_ms" => 1_000,
      "preferred_duration_ms" => 1_500,
      "maximum_duration_ms" => 2_000,
      "timing_rationale" => "待补充",
      "camera" => %{
        "shot_size" => "中景",
        "angle" => "平视",
        "movement" => "static",
        "visual_focus" => "待补充",
        "composition_notes" => "",
        "lens_intent" => ""
      },
      "staging" => %{
        "location_ref" => "location:unspecified",
        "participant_refs" => [],
        "prop_refs" => [],
        "blocking_notes" => ""
      },
      "audio_strategy" => %{
        "mode" => "no_dialogue",
        "dialogue_event_ids" => [],
        "sound_notes" => ""
      },
      "continuity" => %{
        "start_state" => [],
        "actions" => [],
        "end_state" => [],
        "relation_to_previous" => "cut"
      },
      "constraints" => %{
        "must_show" => [],
        "must_not_show" => [],
        "reference_object_ids" => []
      }
    }
  end

  defp shot_item(_collection, _scene_id), do: %{"id" => generated_id("SHOT")}

  defp mutate_visual_draft(socket, draft_id, mutation) do
    draft = Repo.get!(Draft, draft_id)
    changed = mutation.(draft.payload)

    result =
      with :visual_design <- draft.kind,
           {:ok, payload} <-
             VisualDesignDraftForm.cast(
               VisualDesignDraftForm.from_payload(changed),
               draft.payload
             ) do
        Revisions.replace_draft_payload(draft, payload)
      else
        {:error, errors} -> {:error, {:form_validation, errors}}
        _other -> {:error, :invalid_visual_design}
      end

    {:noreply, result_flash(socket, result, "VisualDesign Draft 已更新。") |> load_workspace()}
  end

  defp visual_item("objects", type) do
    %{
      "id" => generated_id(String.upcase(type)),
      "type" => type,
      "name" => "新#{visual_type_label(type)}",
      "narrative_role" => "待补充",
      "importance" => "supporting",
      "recurring" => false,
      "key" => false,
      "reference_required" => false,
      "source_semantics" => "creative",
      "description" => "待补充视觉定义",
      "palette" => [],
      "materials" => [],
      "must_show" => [],
      "must_not_show" => [],
      "type_details" => %{},
      "variants" => [visual_item("variants:new", type)]
    }
  end

  defp visual_item("variants:" <> _object_id, type) do
    %{
      "id" => generated_id("VAR"),
      "name" => "新状态",
      "state_description" => "待补充",
      "wardrobe" => "",
      "lighting" => "",
      "required_slots" => visual_slots(type)
    }
  end

  defp visual_item(_collection, _type), do: %{"id" => generated_id("VIS")}

  defp visual_collection_type(_payload, "objects", type) when type in ~w(character location prop),
    do: type

  defp visual_collection_type(payload, "variants:" <> object_id, _type) do
    (payload["objects"] || [])
    |> Enum.find(%{}, &(&1["id"] == object_id))
    |> Map.get("type", "character")
  end

  defp visual_collection_type(_payload, _collection, _type), do: "character"

  defp visual_slots(type) do
    case Visuals.slot_template(type) do
      {:ok, slots} -> slots
      :error -> []
    end
  end

  defp visual_type_label("character"), do: "角色"
  defp visual_type_label("location"), do: "场景"
  defp visual_type_label("prop"), do: "道具"
  defp visual_type_label(_type), do: "对象"

  defp mutate_narrative_draft(socket, draft_id, mutation) do
    draft = Repo.get!(Draft, draft_id)
    changed = mutation.(draft.payload)

    result =
      with :narrative <- draft.kind,
           {:ok, payload} <-
             NarrativeDraftForm.cast(NarrativeDraftForm.from_payload(changed), draft.payload) do
        Revisions.replace_draft_payload(draft, payload)
      else
        {:error, errors} -> {:error, {:form_validation, errors}}
        _other -> {:error, :invalid_narrative_draft}
      end

    {:noreply, result_flash(socket, result, "Narrative Draft 已更新。") |> load_workspace()}
  end

  defp narrative_item("scenes") do
    %{
      "id" => generated_id("SC"),
      "title" => "新场景",
      "location_ref" => "location:unspecified",
      "time_of_day" => "未指定",
      "goal" => "待补充",
      "summary" => "待补充",
      "source_semantics" => "creative",
      "beats" => []
    }
  end

  defp narrative_item("beats:" <> _scene_id) do
    %{
      "id" => generated_id("BT"),
      "title" => "新节拍",
      "goal" => "待补充",
      "summary" => "待补充",
      "story_event_ids" => []
    }
  end

  defp narrative_item("story_events") do
    %{
      "id" => generated_id("EV"),
      "name" => "新事件",
      "description" => "待补充",
      "subject_refs" => [],
      "source_semantics" => "creative"
    }
  end

  defp narrative_item("dialogue_events") do
    %{
      "id" => generated_id("DL"),
      "speaker_ref" => "character:unspecified",
      "text" => "待补充",
      "scene_id" => "",
      "beat_id" => "",
      "story_event_id" => "",
      "source_semantics" => "creative",
      "start_ms" => 0,
      "end_ms" => 1_000
    }
  end

  defp narrative_item("dependencies") do
    %{
      "id" => generated_id("DP"),
      "kind" => "other",
      "name" => "新依赖",
      "source_semantics" => "creative"
    }
  end

  defp narrative_item("conflicts") do
    %{"id" => generated_id("CF"), "description" => "待决项", "severity" => "warning"}
  end

  defp narrative_item(_collection), do: %{"id" => generated_id("ITEM")}

  defp generated_id(prefix), do: "#{prefix}-#{String.slice(Ecto.UUID.generate(), 0, 8)}"

  defp source_revisions(project_id) do
    Repo.all(
      from revision in SourceRevision,
        where: revision.project_id == ^project_id,
        order_by: [asc: revision.inserted_at]
    )
  end

  defp project_drafts(project_id) do
    Repo.all(
      from draft in Draft,
        where: draft.project_id == ^project_id,
        order_by: [desc: draft.inserted_at]
    )
  end

  defp reload_execution_slice(socket, :ignore), do: socket

  defp reload_execution_slice(socket, :execution),
    do: socket |> load_execution_slice() |> load_analysis_slice() |> refresh_stage_states()

  defp reload_execution_slice(socket, :analysis),
    do: socket |> load_execution_slice() |> load_analysis_slice() |> refresh_stage_states()

  defp reload_execution_slice(socket, :generation),
    do: socket |> load_execution_slice() |> load_generation_slice() |> refresh_stage_states()

  defp reload_execution_slice(socket, :timeline),
    do: socket |> load_execution_slice() |> load_timeline_slice() |> refresh_stage_states()

  defp reload_execution_slice(socket, :changes),
    do: socket |> load_execution_slice() |> load_changes_slice() |> refresh_stage_states()

  defp load_execution_slice(socket) do
    project_id = socket.assigns.project.id

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

    socket
    |> assign(:runs, runs)
    |> assign(:all_nodes, nodes)
    |> assign(:nodes, current_nodes(nodes, runs))
    |> assign(:attempts, attempt_traces(project_id))
    |> assign(:costs, Repo.all(from cost in CostEntry, where: cost.project_id == ^project_id))
  end

  defp load_analysis_slice(socket) do
    snapshots =
      Repo.all(
        from snapshot in AnalysisSnapshot,
          where: snapshot.project_id == ^socket.assigns.project.id,
          order_by: [desc: snapshot.inserted_at]
      )
      |> current_analysis_snapshots(socket.assigns.runs)

    socket
    |> assign(:analysis_snapshots, snapshots)
    |> assign(:episode_candidates, episode_candidates(snapshots))
  end

  defp load_generation_slice(socket) do
    project_id = socket.assigns.project.id
    drafts = project_drafts(project_id)
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

    candidates =
      build_candidates(
        assets,
        specs,
        reports,
        selections,
        socket.assigns.attempts,
        socket.assigns.costs
      )

    socket
    |> assign(:drafts, drafts)
    |> assign(:specs, specs)
    |> assign(:assets, assets)
    |> assign(:selections, selections)
    |> assign(:candidates, candidates)
    |> assign(
      :reference_candidates,
      Enum.filter(candidates, &String.starts_with?(&1.slot_key, "reference:"))
    )
    |> assign(
      :shot_candidates,
      Enum.filter(candidates, &String.starts_with?(&1.slot_key, "shot:"))
    )
    |> assign(
      :reference_assets,
      Enum.filter(assets, &String.starts_with?(&1.mime_type, "image/"))
    )
  end

  defp load_timeline_slice(socket) do
    project_id = socket.assigns.project.id

    timeline =
      Repo.one(
        from timeline in TimelineRecord,
          where: timeline.project_id == ^project_id,
          order_by: [desc: timeline.inserted_at],
          limit: 1
      )

    renders =
      Repo.all(
        from manifest in RenderManifest,
          where: manifest.project_id == ^project_id,
          order_by: [desc: manifest.inserted_at]
      )

    socket
    |> assign(:timeline, timeline)
    |> assign(:clips, if(timeline, do: TimelineContext.list_clips(timeline), else: []))
    |> assign(:subtitles, if(timeline, do: TimelineContext.list_subtitles(timeline), else: []))
    |> assign(:renders, renders)
  end

  defp load_changes_slice(socket) do
    project_id = socket.assigns.project.id

    stale_records =
      Repo.all(
        from stale in StaleRecord,
          where: stale.project_id == ^project_id and stale.resolution == :unresolved,
          order_by: [desc: stale.inserted_at]
      )

    change_sets =
      Repo.all(
        from change in ChangeSet,
          where: change.project_id == ^project_id,
          order_by: [desc: change.inserted_at]
      )

    socket
    |> assign(:stale_records, stale_records)
    |> assign(:change_sets, change_sets)
  end

  defp refresh_stage_states(socket) do
    data = %{
      source_revisions: socket.assigns.source_revisions,
      runs: socket.assigns.runs,
      nodes: socket.assigns.all_nodes,
      snapshots: socket.assigns.analysis_snapshots,
      drafts: socket.assigns.drafts,
      revisions: socket.assigns.revisions,
      specs: socket.assigns.specs,
      candidates: socket.assigns.candidates,
      selections: socket.assigns.selections,
      stale_records: socket.assigns.stale_records,
      timeline: socket.assigns.timeline,
      renders: socket.assigns.renders,
      attempts: socket.assigns.attempts
    }

    states = stage_states(data)

    socket
    |> assign(:stage_states, states)
    |> assign(:state, Map.fetch!(states, socket.assigns.stage))
  end

  defp load_workspace(socket) do
    project_id = socket.assigns.project.id
    source_revisions = source_revisions(project_id)

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
      |> current_analysis_snapshots(runs)

    drafts = project_drafts(project_id)

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
    |> assign(:all_nodes, nodes)
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

  defp enqueue_specs(project, specs, task_type) do
    Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, runs} ->
      case Generation.enqueue_pipeline(project, spec, task_type) do
        {:ok, run} -> {:cont, {:ok, [run | runs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp retry_generation_pipeline(project, spec, task_type, opts) do
    with {:ok, run} <- Generation.enqueue_pipeline(project, spec, task_type, opts) do
      case Repo.one(
             from node in NodeRun,
               where: node.workflow_run_id == ^run.id and node.status == :failed,
               order_by: [asc: node.inserted_at],
               limit: 1
           ) do
        nil -> {:ok, run}
        failed -> retry_node(failed)
      end
    end
  end

  defp retry_node(%NodeRun{} = node) do
    with {:ok, worker} <- registered_worker(node.worker),
         {:ok, queued} <- Workflow.retry_node(node),
         run <- Repo.get!(WorkflowRun, queued.workflow_run_id),
         {:ok, _running} <- Workflow.mark_run(run, :running),
         {:ok, %{node: owned}} <- Enqueue.node(queued, worker) do
      {:ok, owned}
    end
  end

  defp registered_worker(name) do
    case WorkerRegistry.fetch(name) do
      {:ok, worker} -> {:ok, worker}
      :error -> {:error, :unregistered_worker}
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

  defp current_nodes(nodes, runs) do
    case latest_analysis_run(runs) do
      nil -> []
      run -> Enum.filter(nodes, &(&1.workflow_run_id == run.id))
    end
  end

  defp latest_analysis_run(runs),
    do: Enum.find(runs, &(&1.definition_key == "whole_novel_analysis_v1"))

  defp current_analysis_snapshots(snapshots, runs) do
    case latest_analysis_run(runs) do
      nil -> []
      run -> Enum.filter(snapshots, &(&1.workflow_run_id == run.id))
    end
  end

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
          stale? ->
            :stale

          shot_plan? and data.candidates != [] and data.selections != [] ->
            :ready

          true ->
            workflow_state(data, ["image_generation_v1"], :waiting_user)
        end,
      timeline:
        cond do
          stale? ->
            :stale

          Enum.any?(data.renders, &(&1.status == :failed)) ->
            :failed

          Enum.any?(data.renders, &(&1.status in [:prepared, :rendering])) ->
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
    case latest_analysis_run(data.runs) do
      nil ->
        :waiting_user

      run ->
        nodes = Enum.filter(data.nodes, &(&1.workflow_run_id == run.id))
        snapshot? = Enum.any?(data.snapshots, &(&1.workflow_run_id == run.id))

        cond do
          run.status in [:failed, :cancelled] -> :failed
          Enum.any?(nodes, &(&1.status in [:failed, :cancelled])) -> :failed
          run.status in [:pending, :running] -> :loading
          run.status == :succeeded and snapshot? -> :ready
          run.status == :succeeded -> :failed
          true -> :waiting_user
        end
    end
  end

  defp runs_state(data) do
    current_runs = current_workflow_runs(data.runs, data.specs)
    run_ids = MapSet.new(current_runs, & &1.id)
    current_nodes = Enum.filter(data.nodes, &MapSet.member?(run_ids, &1.workflow_run_id))

    cond do
      current_runs == [] ->
        :empty

      Enum.any?(current_nodes, &(&1.status == :failed)) or
          Enum.any?(current_runs, &(&1.status == :failed)) ->
        :failed

      Enum.any?(current_nodes, &(&1.status in [:queued, :running])) or
          Enum.any?(current_runs, &(&1.status in [:pending, :running])) ->
        :loading

      true ->
        :ready
    end
  end

  defp workflow_state(data, definition_keys, fallback) do
    relevant_runs =
      data.runs
      |> Enum.filter(&(&1.definition_key in definition_keys))
      |> current_workflow_runs(data.specs)

    run_ids = MapSet.new(relevant_runs, & &1.id)
    relevant_nodes = Enum.filter(data.nodes, &MapSet.member?(run_ids, &1.workflow_run_id))

    cond do
      Enum.any?(relevant_nodes, &(&1.status == :failed)) or
          Enum.any?(relevant_runs, &(&1.status == :failed)) ->
        :failed

      Enum.any?(relevant_nodes, &(&1.status in [:queued, :running])) or
          Enum.any?(relevant_runs, &(&1.status in [:pending, :running])) ->
        :loading

      true ->
        fallback
    end
  end

  defp current_workflow_runs(runs, specs) do
    specs_by_id = Map.new(specs, &{&1.id, &1})

    runs
    |> Enum.group_by(&workflow_identity(&1, specs_by_id))
    |> Enum.map(fn {_identity, versions} ->
      Enum.max_by(versions, &{&1.inserted_at, &1.id})
    end)
  end

  defp workflow_identity(%{definition_key: "image_generation_v1"} = run, specs) do
    spec = Map.get(specs, run.input_snapshot["generation_spec_id"])
    payload = if spec, do: spec.payload, else: %{}

    slot =
      payload["slot_key"] || payload["shot_id"] || payload["reference_slot"] ||
        payload["object_id"] || (spec && spec.kind) || run.input_snapshot["generation_spec_id"]

    {
      run.definition_key,
      run.input_snapshot["task_type"],
      slot,
      spec && spec.candidate_index,
      spec && spec.formal
    }
  end

  defp workflow_identity(%{definition_key: "structured_proposal_v1"} = run, _specs),
    do: {run.definition_key, run.input_snapshot["task_type"]}

  defp workflow_identity(%{definition_key: "whole_novel_analysis_v1"} = run, _specs),
    do: {run.definition_key}

  defp workflow_identity(%{definition_key: "timeline_render_v1"} = run, _specs),
    do: {run.definition_key, run.input_snapshot["render_mode"]}

  defp workflow_identity(run, _specs),
    do: {run.definition_key, run.idempotency_key}

  defp latest_revision(revisions, kind), do: Enum.find(revisions, &(&1.kind == kind))
  defp drafts_for(drafts, kind), do: Enum.filter(drafts, &(&1.kind == kind))

  defp workflow_active?(runs, definition_key) do
    Enum.any?(runs, &(&1.definition_key == definition_key and &1.status in [:pending, :running]))
  end

  defp analysis_workflow_active?(runs, project, provider_mode) do
    {:ok, current_execution} = DAG.execution_snapshot(project, provider_mode: provider_mode)

    Enum.any?(runs, fn run ->
      run.definition_key == "whole_novel_analysis_v1" and
        run.status in [:pending, :running] and
        analysis_execution_matches?(run, current_execution)
    end)
  end

  defp analysis_execution_matches?(run, current_execution) do
    case run.input_snapshot["execution"] do
      nil -> current_execution["provider_mode"] == "openai"
      persisted_execution -> persisted_execution == current_execution
    end
  end

  defp generation_active?(runs) do
    Enum.any?(runs, fn run ->
      run.definition_key in ["structured_proposal_v1", "image_generation_v1"] and
        run.status in [:pending, :running]
    end)
  end

  defp result_flash(socket, {:ok, _value}, message), do: put_flash(socket, :info, message)

  defp result_flash(socket, {:error, reason}, _message),
    do: put_flash(socket, :error, human_error(reason))

  defp result_flash(socket, other, _message), do: put_flash(socket, :error, human_error(other))

  defp human_error({:unresolved_stale, _ids}), do: "仍有未解决的过期选择，需先固定旧输入或替换。"
  defp human_error({:form_validation, _errors}), do: "表单存在缺失或冲突字段，请检查后再保存。"
  defp human_error(:confirmed_timeline_inputs_required), do: "请先确认 Narrative 与 ShotPlan。"
  defp human_error(:analysis_snapshot_required), do: "请先完成全文分析。"
  defp human_error(:unknown_remote_state), do: "远端执行结果未知，已禁止自动重提。"
  defp human_error(:node_dependencies_incomplete), do: "上游节点尚未成功，当前节点不能重试。"
  defp human_error(:invalid_json), do: "JSON 格式无效。"
  defp human_error(:invalid_candidate_count), do: "候选数量必须是正整数。"
  defp human_error(:shot_selection_required), do: "时间线只能使用镜头候选，不能使用参考图。"
  defp human_error(reason), do: inspect(reason)

  defp stale_label("old_input_in_flight"), do: "旧输入任务仍在 Provider 执行"
  defp stale_label("upstream_revision_changed"), do: "上游权威已变化"
  defp stale_label(reason), do: reason || "输入已过期"

  defp stale_guidance("old_input_in_flight"),
    do: "任务结果会保留在旧输入闭包下；完成后可固定旧输入或改选新候选。"

  defp stale_guidance(_reason), do: "正式导出前必须明确固定旧输入或替换为新候选。"

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

  defp generation_task_type("reference_image"), do: {:ok, :reference_image}
  defp generation_task_type("shot_keyframe"), do: {:ok, :shot_keyframe}
  defp generation_task_type("image_edit"), do: {:ok, :image_edit}
  defp generation_task_type(_kind), do: {:error, :unsupported_generation_task}

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

  defp node_state(:queued), do: :queued
  defp node_state(:running), do: :loading
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

  defp next_stage(:source), do: :analysis
  defp next_stage(:analysis), do: :episodes
  defp next_stage(:episodes), do: :visuals
  defp next_stage(:visuals), do: :shots
  defp next_stage(:shots), do: :timeline
  defp next_stage(:timeline), do: :runs
  defp next_stage(:runs), do: :source

  defp next_action_label(:source), do: "导入完成后，检查整本事实分析"
  defp next_action_label(:analysis), do: "确认分析结果并选择分集候选"
  defp next_action_label(:episodes), do: "冻结 Narrative，进入视觉权威"
  defp next_action_label(:visuals), do: "确认主参考图，进入导演方案"
  defp next_action_label(:shots), do: "选择镜头主图，组装时间线"
  defp next_action_label(:timeline), do: "检查预览与正式导出记录"
  defp next_action_label(:runs), do: "回到原著或继续检查运行恢复"

  defp next_action_button(:source), do: "查看全文解析"
  defp next_action_button(:analysis), do: "选择分集候选"
  defp next_action_button(:episodes), do: "进入视觉设计"
  defp next_action_button(:visuals), do: "进入镜头制作"
  defp next_action_button(:shots), do: "进入时间线"
  defp next_action_button(:timeline), do: "查看运行记录"
  defp next_action_button(:runs), do: "返回原著"

  defp stage_path(project_id, :source), do: ~p"/projects/#{project_id}/source"
  defp stage_path(project_id, :analysis), do: ~p"/projects/#{project_id}/analysis"
  defp stage_path(project_id, :episodes), do: ~p"/projects/#{project_id}/episodes"
  defp stage_path(project_id, :visuals), do: ~p"/projects/#{project_id}/visuals"
  defp stage_path(project_id, :shots), do: ~p"/projects/#{project_id}/shots"
  defp stage_path(project_id, :timeline), do: ~p"/projects/#{project_id}/timeline"
  defp stage_path(project_id, :runs), do: ~p"/projects/#{project_id}/runs"

  defp kind_label(:narrative), do: "Narrative"
  defp kind_label(:visual_design), do: "VisualDesign"
  defp kind_label(:shot_plan), do: "ShotPlan"
  defp kind_label(kind), do: Atom.to_string(kind)
end
