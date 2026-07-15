defmodule Dramatizer.Acceptance.RealProviderSmokeTest do
  use Dramatizer.DataCase, async: false

  import Ecto.Query

  alias Dramatizer.Analysis.{DAG, Runner}
  alias Dramatizer.Assets
  alias Dramatizer.Costs.CostEntry
  alias Dramatizer.Directing
  alias Dramatizer.Directing.Compiler
  alias Dramatizer.Generation
  alias Dramatizer.Generation.{Attempt, GenerationSpec, Orchestrator, ProviderRequestSnapshot}
  alias Dramatizer.Media.Worker
  alias Dramatizer.Projects
  alias Dramatizer.Quality
  alias Dramatizer.Quality.QualityReport
  alias Dramatizer.Repo
  alias Dramatizer.Revisions
  alias Dramatizer.Sources
  alias Dramatizer.Sources.SourceRevision
  alias Dramatizer.Timeline
  alias Dramatizer.Timeline.RenderRecipe
  alias Dramatizer.Visuals
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.NodeRun
  alias Dramatizer.Workflow.WorkflowRun

  setup tags do
    if tags[:real_provider] do
      :ok
    else
      isolated_asset_root()
    end
  end

  defp isolated_asset_root do
    previous_root = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "dramatizer-real-contract-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous_root)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "the shared orchestrator dispatches the OpenAI image branch with persisted QC lineage" do
    assert {:ok, project} = Projects.create_project(%{name: "OpenAI 分派合同"})

    assert {:ok, spec} =
             Dramatizer.Generation.create_spec(project, %{
               kind: "shot_keyframe",
               candidate_index: 0,
               formal: true,
               payload: %{
                 "shot_id" => "S001",
                 "width" => 270,
                 "height" => 480,
                 "aspect_width" => 9,
                 "aspect_height" => 16,
                 "prompt" => "雨夜车站中的林夏"
               }
             })

    image_submitter = fn snapshot, _attempt ->
      assert snapshot.adapter == "openai_images"
      assert snapshot.model == "gpt-image-2"
      assert snapshot.request_input["operation"] == "generate"

      assert {:ok, generated} =
               Worker.run(:generate_fake_image, %{
                 "width" => 270,
                 "height" => 480,
                 "seed" => snapshot.request_hash
               })

      {:ok, bytes} = Base.decode64(generated["png_base64"])

      {:ok,
       %{
         images: [%{bytes: bytes, mime_type: "image/png"}],
         request_id: "img_contract_001",
         external_request_id: "img_contract_001",
         usage: %{"total_tokens" => 17},
         response_metadata: %{"request_id" => "img_contract_001"}
       }}
    end

    semantic_evaluator = fn _snapshot, _attempt ->
      {:ok,
       %{
         output: %{"dimensions" => semantic_dimensions()},
         external_request_id: "qc_contract_001",
         request_id: "qc_contract_001",
         usage: %{"total_tokens" => 11}
       }}
    end

    assert {:ok, generated} =
             Orchestrator.generate(spec, :shot_keyframe, project,
               provider_mode: :openai,
               task_override: %{
                 adapter: "openai_images",
                 credential_ref: "none",
                 model: "gpt-image-2",
                 params: %{
                   "candidate_count" => 2,
                   "quality" => "low",
                   "size" => "270x480"
                 }
               },
               image_submitter: image_submitter,
               semantic_evaluator: semantic_evaluator
             )

    assert generated.request_snapshot.adapter == "openai_images"
    assert generated.attempt.status == :succeeded
    assert generated.attempt.external_request_id == "img_contract_001"
    assert generated.attempt.response_metadata["usage"]["total_tokens"] == 17
    assert generated.asset.lineage["origin"] == "openai_images"
    assert generated.asset.lineage["attempt_id"] == generated.attempt.id
    assert generated.technical_qc.status == :pass
    assert generated.semantic_qc.status == :pass
  end

  @tag :real_provider
  @tag timeout: 1_800_000
  @tag ownership_timeout: 1_800_000
  test "AT-005 bounded OpenAI text, image, semantic QC, and formal Animatic closure" do
    assert System.get_env("DRAMATIZER_REAL_SMOKE") == "1"
    api_key = System.get_env("OPENAI_API_KEY")
    assert is_binary(api_key) and byte_size(api_key) > 0

    assert {:ok, project} = Projects.create_project(%{name: "AT-005 OpenAI 有界烟测"})
    configure_bounded_openai(project)

    source_path = write_source_fixture()
    assert {:ok, _document, source} = Sources.import(project, source_path)
    assert {:ok, run, _nodes} = DAG.start(project, [source.id])

    analysis =
      case run_analysis_with_one_transient_resume(project, run) do
        {:ok, completed} ->
          completed

        {:error, reason} ->
          diagnostics =
            Repo.all(
              from node in NodeRun,
                where: node.workflow_run_id == ^run.id and node.status == :failed,
                select: %{
                  node_key: node.node_key,
                  error_code: node.error_code,
                  validation_errors: node.result["validation_errors"]
                }
            )

          IO.puts(
            "DRAMATIZER_REAL_SMOKE_DIAGNOSTIC=" <>
              Jason.encode!(%{reason: reason, failed_nodes: diagnostics})
          )

          flunk("real analysis failed: #{inspect(reason)}")
      end

    nodes =
      Repo.all(
        from node in NodeRun,
          where: node.workflow_run_id == ^run.id,
          order_by: [asc: node.inserted_at]
      )

    assert length(nodes) == 6
    assert Enum.all?(nodes, &(&1.status == :succeeded))
    episode_items = get_in(analysis.node_results, ["episode_candidates", "output", "items"])
    assert is_list(episode_items) and episode_items != []
    episode = hd(episode_items)

    narrative =
      confirmed(project, :narrative, %{
        "episode_id" => episode["id"],
        "title" => episode["name"],
        "analysis_snapshot_id" => analysis.id,
        "source_revision_ids" => [source.id],
        "dialogue_events" => [
          dialogue("D001", "S001", "雨下得更急了。", 100, 1_050),
          dialogue("D002", "S002", "这封信没有署名。", 1_150, 2_150),
          dialogue("D003", "S003", "寄信的人还在附近。", 2_250, 3_350)
        ]
      })

    assert {:ok, visual_draft} =
             Visuals.create_design_draft(project, narrative, [
               %{
                 "id" => "character:linxia",
                 "type" => "character",
                 "name" => "林夏",
                 "recurring" => true,
                 "key" => true,
                 "variants" => [%{"id" => "raincoat"}]
               }
             ])

    assert {:ok, visual} = Revisions.confirm_draft(visual_draft.id)

    required_slots =
      get_in(visual.payload, ["objects", Access.at(0), "variants", Access.at(0), "required_slots"])

    assert length(required_slots) == 3

    reference_results =
      Enum.map(required_slots, fn slot ->
        assert {:ok, spec} =
                 Generation.create_spec(project, %{
                   revision_id: visual.id,
                   kind: "reference_image",
                   candidate_index: 0,
                   formal: true,
                   payload: %{
                     "object_id" => "character:linxia",
                     "variant_id" => "raincoat",
                     "slot" => slot,
                     "角色" => "林夏，二十七岁，黑色齐耳短发，深蓝色雨衣",
                     "场景" => "中性灰背景的角色设定图",
                     "必须出现" => ["同一张亚洲女性面孔", "深蓝色雨衣"],
                     "禁止出现" => ["文字", "水印", "其他人物"],
                     "width" => 768,
                     "height" => 1360,
                     "aspect_width" => 768,
                     "aspect_height" => 1360
                   }
                 })

        assert {:ok, generated} =
                 Orchestrator.generate(spec, :reference_image, project, provider_mode: :openai)

        assert generated.technical_qc.status == :pass
        refute generated.semantic_qc.status == :evaluator_failed
        {"character:linxia/raincoat/#{slot}", generated}
      end)

    assignments =
      Map.new(reference_results, fn {slot, generated} -> {slot, generated.asset.id} end)

    assert {:ok, reference_draft} =
             Visuals.create_reference_set_draft(project, visual, assignments)

    assert {:ok, reference_set} = Revisions.confirm_draft(reference_draft.id)

    assert {:ok, shot_draft} =
             Directing.create_shot_plan_draft(project, narrative, visual, %{
               "scenes" => [%{"id" => "SC001", "name" => "雨夜旧车站"}],
               "shots" => shot_plan(),
               "continuity" => %{"character_variant" => "raincoat"}
             })

    assert {:ok, shot_plan} = Revisions.confirm_draft(shot_draft.id)

    assert {:ok, compiled_revision} =
             Compiler.compile_revision(
               project,
               %{
                 narrative: narrative,
                 visual_design: visual,
                 reference_set: reference_set,
                 shot_plan: shot_plan
               },
               source_revision_ids: [source.id]
             )

    shot_results =
      compiled_revision.payload["specs"]
      |> Enum.flat_map(fn compiled ->
        for candidate_index <- 0..1 do
          payload =
            compiled["payload"]
            |> Map.put("shot_id", compiled["shot_id"])
            |> Map.put("prompt", "保持林夏与三张已确认参考图一致，电影级中国竖屏短剧关键帧")

          assert {:ok, spec} =
                   Generation.create_spec(project, %{
                     revision_id: compiled_revision.id,
                     kind: "shot_keyframe",
                     candidate_index: candidate_index,
                     formal: true,
                     payload: payload
                   })

          assert {:ok, generated} =
                   Orchestrator.generate(spec, :shot_keyframe, project, provider_mode: :openai)

          assert generated.technical_qc.status == :pass
          refute generated.semantic_qc.status == :evaluator_failed
          generated
        end
      end)

    assert length(shot_results) == 6

    selections =
      shot_results
      |> Enum.group_by(& &1.spec.payload["shot_id"])
      |> Map.new(fn {shot_id, candidates} ->
        chosen = Enum.min_by(candidates, & &1.spec.candidate_index)

        assert {:ok, decision} =
                 Quality.select(project, "shot:#{shot_id}", chosen.spec, chosen.asset,
                   note: "AT-005 显式烟测选择 candidate 0"
                 )

        {shot_id, decision}
      end)

    assert map_size(selections) == 3
    assert {:ok, timeline} = Timeline.create(project, narrative, shot_plan, selections)
    assert {:ok, version} = Timeline.freeze(timeline)
    assert {:ok, formal} = RenderRecipe.formal(version)
    assert {:ok, rendered} = Timeline.render(formal)
    assert rendered.status == :rendered
    assert rendered.technical_qc["status"] == "pass"

    trace_final_clips!(timeline, compiled_revision, shot_plan, visual, narrative, source)

    summary =
      verification_summary(project, nodes, reference_results, shot_results, timeline, rendered)

    assert summary["decision"] == "pass"
    assert summary["reference_images"] == 3
    assert summary["shot_candidates"] == 6
    assert summary["final_clips"] == 3

    snapshots = project_snapshots(project.id)
    assert snapshots != []
    serialized_snapshots = Jason.encode!(Enum.map(snapshots, &snapshot_payload/1))
    refute serialized_snapshots =~ api_key
    refute serialized_snapshots =~ "Bearer "
    assert Enum.all?(snapshots, &(&1.request_hash && byte_size(&1.request_hash) == 64))
    assert Enum.all?(snapshots, &(byte_size(&1.prompt_snapshot["config_hash"]) == 64))
    assert Enum.all?(snapshots, &(byte_size(&1.prompt_snapshot["prompt_hash"]) == 64))

    text_snapshots = Enum.filter(snapshots, &(&1.adapter == "openai_responses"))
    image_snapshots = Enum.filter(snapshots, &(&1.adapter == "openai_images"))
    assert Enum.all?(text_snapshots, &(byte_size(&1.prompt_snapshot["schema_hash"]) == 64))
    assert Enum.all?(image_snapshots, &(&1.prompt_snapshot["provider_prompt_hash"] != nil))

    IO.puts("DRAMATIZER_REAL_SMOKE_RESULT=#{Jason.encode!(summary)}")
  end

  defp configure_bounded_openai(project) do
    text = %{
      adapter: "openai_responses",
      credential_ref: "OPENAI_API_KEY",
      model: "gpt-5.6-terra",
      params: %{"reasoning" => %{"effort" => "low"}}
    }

    for task <-
          ~w(people_relations places_props_world events_timeline entity_merge episode_candidates conflict_check semantic_qc)a do
      assert {:ok, _override} = Projects.put_model_override(project, task, text)
    end

    image = %{
      adapter: "openai_images",
      credential_ref: "OPENAI_API_KEY",
      model: "gpt-image-2",
      params: %{"quality" => "low", "size" => "768x1360"}
    }

    assert {:ok, _reference_override} =
             Projects.put_model_override(
               project,
               :reference_image,
               put_in(image, [:params, "candidate_count"], 1)
             )

    assert {:ok, _shot_override} =
             Projects.put_model_override(
               project,
               :shot_keyframe,
               put_in(image, [:params, "candidate_count"], 2)
             )
  end

  defp run_analysis_with_one_transient_resume(project, run) do
    case Runner.run(project, run, :openai) do
      {:ok, completed} ->
        {:ok, completed}

      {:error, :provider_failed} = error ->
        failed =
          Repo.one(
            from node in NodeRun,
              where: node.workflow_run_id == ^run.id and node.status == :failed,
              order_by: [desc: node.completed_at],
              limit: 1
          )

        transient? =
          Enum.any?(get_in(failed.result, ["validation_errors"]) || [], fn item ->
            item["code"] in ["provider_unavailable", "provider_timeout", "rate_limited"]
          end)

        if transient? do
          assert {:ok, _queued} = Workflow.retry_node(failed)
          current_run = Repo.get!(WorkflowRun, run.id)
          Runner.run(project, current_run, :openai)
        else
          error
        end

      error ->
        error
    end
  end

  defp write_source_fixture do
    path =
      Path.join(
        System.tmp_dir!(),
        "dramatizer-real-smoke-#{System.unique_integer([:positive])}.md"
      )

    body = """
    # 雨夜来信

    夜里十一点，旧车站被大雨包围。二十七岁的林夏穿着深蓝色雨衣，黑色齐耳短发贴在脸侧。她站在停运的三号站台，手里握着一封没有署名的牛皮纸信。

    信里只有一句话：“别上最后一班车。”远处的钟声连续响了三次，候车室的灯忽明忽暗。林夏认出信纸右下角有弟弟林川惯用的三角折痕，但林川已经失踪半年。

    广播突然响起，提醒并不存在的末班车即将进站。铁轨尽头出现一束白光。林夏把信收进口袋，看见玻璃倒影里有一个撑黑伞的人正站在她身后；她回头时，站台上却空无一人。
    """

    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp confirmed(project, kind, payload) do
    assert {:ok, draft} =
             Revisions.create_draft(project, kind, payload, %{"real_smoke" => true})

    assert {:ok, revision} = Revisions.confirm_draft(draft.id)
    revision
  end

  defp dialogue(id, shot_id, text, start_ms, end_ms) do
    %{
      "id" => id,
      "shot_id" => shot_id,
      "text" => text,
      "start_ms" => start_ms,
      "end_ms" => end_ms,
      "style" => %{"position" => "safe_bottom"}
    }
  end

  defp shot_plan do
    [
      %{
        "id" => "S001",
        "scene_id" => "SC001",
        "action" => "林夏在雨夜站台低头查看匿名信",
        "camera" => "push_in",
        "minimum_duration_ms" => 1_000,
        "preferred_duration_ms" => 1_250,
        "maximum_duration_ms" => 1_800,
        "must_include" => ["林夏", "深蓝色雨衣", "牛皮纸信"],
        "must_forbid" => ["其他人物", "可读文字", "水印"]
      },
      %{
        "id" => "S002",
        "scene_id" => "SC001",
        "action" => "匿名信和三角折痕的手部特写",
        "camera" => "pan_left",
        "minimum_duration_ms" => 1_000,
        "preferred_duration_ms" => 1_250,
        "maximum_duration_ms" => 1_800,
        "must_include" => ["林夏的手", "牛皮纸信", "三角折痕"],
        "must_forbid" => ["完整可读信件内容", "水印"]
      },
      %{
        "id" => "S003",
        "scene_id" => "SC001",
        "action" => "林夏望向铁轨白光，玻璃里隐约映出黑伞人",
        "camera" => "pull_out",
        "minimum_duration_ms" => 1_000,
        "preferred_duration_ms" => 1_250,
        "maximum_duration_ms" => 1_800,
        "must_include" => ["林夏", "铁轨白光", "玻璃倒影", "黑伞轮廓"],
        "must_forbid" => ["清晰陌生人面孔", "水印"]
      }
    ]
  end

  defp trace_final_clips!(timeline, compiled_revision, shot_plan, visual, narrative, source) do
    clips = Timeline.list_clips(timeline)
    assert length(clips) == 3

    Enum.each(clips, fn clip ->
      asset = Assets.get_asset!(clip.asset_version_id)
      attempt = Repo.get!(Attempt, asset.lineage["attempt_id"])
      request = Repo.get!(ProviderRequestSnapshot, attempt.provider_request_snapshot_id)
      spec = Repo.get!(GenerationSpec, request.generation_spec_id)
      generation_revision = Revisions.get_revision!(spec.revision_id)

      assert request.model == "gpt-image-2"
      assert attempt.status == :succeeded
      assert generation_revision.id == compiled_revision.id

      assert get_in(generation_revision.payload, [
               "frozen_inputs",
               "revisions",
               "shot_plan",
               "id"
             ]) == shot_plan.id

      assert get_in(generation_revision.payload, [
               "frozen_inputs",
               "revisions",
               "visual_design",
               "id"
             ]) == visual.id

      assert get_in(generation_revision.payload, [
               "frozen_inputs",
               "revisions",
               "narrative",
               "id"
             ]) == narrative.id

      assert narrative.payload["source_revision_ids"] == [source.id]
      assert Repo.get!(SourceRevision, source.id).project_id == asset.project_id

      reports =
        Repo.all(
          from report in QualityReport,
            where: report.asset_version_id == ^asset.id,
            order_by: [asc: report.kind]
        )

      assert length(reports) == 2
      assert Enum.find(reports, &(&1.kind == :technical)).status == :pass
      refute Enum.find(reports, &(&1.kind == :semantic)).status == :evaluator_failed
    end)
  end

  defp verification_summary(project, nodes, reference_results, shot_results, timeline, rendered) do
    attempts =
      Repo.all(
        from attempt in Attempt,
          join: request in ProviderRequestSnapshot,
          on: request.id == attempt.provider_request_snapshot_id,
          join: spec in GenerationSpec,
          on: spec.id == request.generation_spec_id,
          where: spec.project_id == ^project.id
      )

    snapshots = project_snapshots(project.id)
    request_ids = attempts |> Enum.map(& &1.external_request_id) |> Enum.reject(&is_nil/1)

    actual_costs =
      Repo.all(
        from cost in CostEntry,
          where: cost.project_id == ^project.id and cost.entry_type == :actual
      )

    quality_reports =
      Repo.all(from report in QualityReport, where: report.project_id == ^project.id)

    output_asset = Assets.get_asset!(rendered.output_asset_id)

    assert {:ok, probe} =
             Worker.run(:probe_video, %{
               "path" => Assets.absolute_path(output_asset),
               "ffmpeg_path" => Application.fetch_env!(:dramatizer, :ffmpeg_path),
               "ffprobe_path" => Application.fetch_env!(:dramatizer, :ffprobe_path)
             })

    assert probe["width"] == 1080
    assert probe["height"] == 1920
    assert probe["video_codec"] == "h264"
    assert probe["pixel_format"] == "yuv420p"
    assert probe["audio_codec"] == "aac"
    assert probe["audio_channels"] == 2

    actual_values = actual_costs |> Enum.map(& &1.amount_micros) |> Enum.reject(&is_nil/1)
    usage = usage_summary(attempts)

    %{
      "decision" => "pass",
      "analysis_nodes" => length(nodes),
      "reference_images" => length(reference_results),
      "shot_candidates" => length(shot_results),
      "final_clips" => length(Timeline.list_clips(timeline)),
      "technical_qc_reports" => Enum.count(quality_reports, &(&1.kind == :technical)),
      "semantic_qc_reports" => Enum.count(quality_reports, &(&1.kind == :semantic)),
      "provider_requests" => length(snapshots),
      "provider_request_ids" => length(request_ids),
      "provider_request_id_digest" => Dramatizer.CanonicalJSON.hash(Enum.sort(request_ids)),
      "usage_units" => usage["total_tokens"],
      "usage" => usage,
      "actual_cost_entries" => length(actual_costs),
      "actual_cost_micros" => if(actual_values == [], do: nil, else: Enum.sum(actual_values)),
      "models" => snapshots |> Enum.map(& &1.model) |> Enum.uniq() |> Enum.sort(),
      "formal_video" => %{
        "width" => probe["width"],
        "height" => probe["height"],
        "video_codec" => probe["video_codec"],
        "pixel_format" => probe["pixel_format"],
        "audio_codec" => probe["audio_codec"],
        "audio_channels" => probe["audio_channels"],
        "asset_hash" => String.slice(output_asset.blob_hash, 0, 16)
      }
    }
  end

  defp project_snapshots(project_id) do
    Repo.all(
      from request in ProviderRequestSnapshot,
        join: spec in GenerationSpec,
        on: spec.id == request.generation_spec_id,
        where: spec.project_id == ^project_id,
        order_by: [asc: request.inserted_at]
    )
  end

  defp snapshot_payload(snapshot) do
    snapshot
    |> Map.from_struct()
    |> Map.take([
      :task_type,
      :adapter,
      :credential_ref,
      :model,
      :params,
      :request_input,
      :prompt_snapshot,
      :request_hash,
      :secrets_excluded
    ])
  end

  defp usage_summary(attempts) do
    usage_maps = Enum.map(attempts, &(&1.response_metadata["usage"] || %{}))

    %{
      "total_tokens" => sum_usage(usage_maps, ["total_tokens"]),
      "input_tokens" => sum_usage(usage_maps, ["input_tokens"]),
      "output_tokens" => sum_usage(usage_maps, ["output_tokens"]),
      "input_image_tokens" => sum_usage(usage_maps, ["input_tokens_details", "image_tokens"]),
      "output_image_tokens" => sum_usage(usage_maps, ["output_tokens_details", "image_tokens"])
    }
  end

  defp sum_usage(usage_maps, path) do
    usage_maps
    |> Enum.map(&(get_in(&1, path) || 0))
    |> Enum.sum()
  end

  defp semantic_dimensions do
    Dramatizer.Quality.SemanticQC.dimensions()
    |> Map.new(fn dimension ->
      {dimension,
       %{
         "status" => "pass",
         "confidence" => 0.99,
         "reason" => "contract fixture",
         "advice" => "none"
       }}
    end)
  end
end
