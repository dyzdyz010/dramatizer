defmodule Dramatizer.Directing.CompilerTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Directing
  alias Dramatizer.Directing.Compiler
  alias Dramatizer.Projects
  alias Dramatizer.Revisions
  alias Dramatizer.Sources

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(System.tmp_dir!(), "dramatizer-compiler-#{System.unique_integer([:positive])}")

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "exact confirmed inputs compile byte-identically and every frozen input affects the hash" do
    assert {:ok, project} = Projects.create_project(%{name: "确定性编译"})
    assert {:ok, _document, source} = Sources.import(project, fixture_path("novel.txt"))
    narrative = confirmed(project, :narrative, %{"episode_id" => "E001", "dialogue" => []})

    visual =
      confirmed(project, :visual_design, %{
        "objects" => [%{"id" => "character:lin", "reference_required" => true}]
      })

    references =
      confirmed(project, :reference_set, %{
        "primary_assets" => %{"character:lin/default/face_closeup" => Ecto.UUID.generate()}
      })

    proposal = %{
      "scenes" => [%{"id" => "SC001", "purpose" => "雨夜重逢"}],
      "shots" => [
        %{
          "id" => "S001",
          "scene_id" => "SC001",
          "action" => "林夏走入车站",
          "preferred_duration_ms" => 2500,
          "must_include" => ["林夏"],
          "must_forbid" => []
        },
        %{
          "id" => "S002",
          "scene_id" => "SC001",
          "action" => "信件特写",
          "preferred_duration_ms" => 1800,
          "must_include" => ["信件"],
          "must_forbid" => []
        }
      ]
    }

    assert {:ok, shot_draft} =
             Directing.create_shot_plan_draft(project, narrative, visual, proposal)

    assert {:error, :unconfirmed_shot_plan} =
             Compiler.compile(
               project,
               %{
                 narrative: narrative,
                 visual_design: visual,
                 reference_set: references,
                 shot_plan: shot_draft
               },
               source_revision_ids: [source.id]
             )

    assert {:ok, shot_plan} = Revisions.confirm_draft(shot_draft.id)

    inputs = %{
      narrative: narrative,
      visual_design: visual,
      reference_set: references,
      shot_plan: shot_plan
    }

    opts = [
      source_revision_ids: [source.id],
      prompt_snapshot_ids: [Ecto.UUID.generate()],
      compiler_config: %{"candidate_count" => 2}
    ]

    assert {:ok, first} = Compiler.compile(project, inputs, opts)
    assert {:ok, second} = Compiler.compile(project, inputs, opts)
    assert first.canonical_json == second.canonical_json
    assert first.hash == second.hash
    assert length(first.payload["specs"]) == 2

    first_spec = hd(first.payload["specs"])["payload"]
    assert first_spec["width"] == 768
    assert first_spec["height"] == 1360

    frozen = first.payload["frozen_inputs"]

    assert frozen["source_revisions"] == [
             %{"id" => source.id, "content_hash" => source.content_hash, "revision" => 1}
           ]

    assert frozen["revisions"]["shot_plan"]["id"] == shot_plan.id
    assert frozen["production_profile"]["aspect_width"] == 9
    assert frozen["production_profile"]["formal_width"] == 1080
    assert frozen["image_generation"]["size"] == "768x1360"
    assert frozen["prompt_snapshot_ids"] == opts[:prompt_snapshot_ids]
    assert frozen["compiler_version"] == "directing-compiler-v2"
    assert frozen["template_version"] == "v1"
    assert frozen["compiler_config"] == %{"candidate_count" => 2}

    changed_opts = Keyword.put(opts, :compiler_config, %{"candidate_count" => 3})
    assert {:ok, changed} = Compiler.compile(project, inputs, changed_opts)
    refute changed.hash == first.hash

    assert {:ok, generation_revision} = Compiler.compile_revision(project, inputs, opts)
    assert generation_revision.kind == :generation_spec
    assert generation_revision.payload == first.payload
  end

  test "rich v2 shots preserve full authority and normalize camera constraints deterministically" do
    assert {:ok, project} = Projects.create_project(%{name: "富导演方案"})
    narrative = confirmed(project, :narrative, %{"episode" => %{"title" => "雨夜来信"}})
    visual = confirmed(project, :visual_design, %{"objects" => []})
    references = confirmed(project, :reference_set, %{"primary_assets" => %{}})

    proposal = %{
      "schema_version" => "shot-plan-draft-v2",
      "scenes" => [%{"id" => "SC001", "name" => "车站", "purpose" => "发现旧信"}],
      "shots" => [rich_shot()],
      "sound_strategy" => "dialogue_first",
      "continuity" => %{"track" => "linear", "notes" => "旧信始终在右手"}
    }

    assert {:ok, draft} = Directing.create_shot_plan_draft(project, narrative, visual, proposal)
    assert {:ok, shot_plan} = Revisions.confirm_draft(draft.id)

    inputs = %{
      narrative: narrative,
      visual_design: visual,
      reference_set: references,
      shot_plan: shot_plan
    }

    assert {:ok, first} = Compiler.compile(project, inputs)
    assert {:ok, second} = Compiler.compile(project, inputs)
    assert first.hash == second.hash

    spec = hd(first.payload["specs"])["payload"]
    assert spec["camera"] == "push_in"
    assert spec["camera_authority"]["shot_size"] == "近景"
    assert spec["must_show"] == ["匿名信"]
    assert spec["must_not_show"] == ["第三人清晰正脸"]
    assert spec["continuity"]["end_state"] == ["右手持信"]
    assert spec["shot"]["presentation_goal"] == "让观众识别旧信上的折痕"
  end

  defp confirmed(project, kind, payload) do
    {:ok, draft} = Revisions.create_draft(project, kind, payload, %{"fixture" => true})
    {:ok, revision} = Revisions.confirm_draft(draft.id)
    revision
  end

  defp rich_shot do
    %{
      "id" => "S001",
      "scene_id" => "SC001",
      "beat_id" => "B001",
      "story_event_ids" => ["EV001"],
      "presentation_goal" => "让观众识别旧信上的折痕",
      "description" => "镜头推近林夏手中的匿名信",
      "shot_class" => "OBJECT_INSERT",
      "coverage" => "primary",
      "minimum_duration_ms" => 1_200,
      "preferred_duration_ms" => 1_800,
      "maximum_duration_ms" => 2_400,
      "timing_rationale" => "留出识别细节的时间",
      "camera" => %{
        "shot_size" => "近景",
        "angle" => "平视",
        "movement" => "push_in",
        "visual_focus" => "匿名信折痕",
        "composition_notes" => "手与信占据画面中央",
        "lens_intent" => "压缩背景"
      },
      "staging" => %{
        "location_ref" => "location:station",
        "participant_refs" => ["character:linxia"],
        "prop_refs" => ["prop:letter"],
        "blocking_notes" => "林夏右手抬起信"
      },
      "audio_strategy" => %{
        "mode" => "no_dialogue",
        "dialogue_event_ids" => [],
        "sound_notes" => "雨声"
      },
      "continuity" => %{
        "start_state" => ["右手持信"],
        "actions" => ["抬起信"],
        "end_state" => ["右手持信"],
        "relation_to_previous" => "continuous"
      },
      "constraints" => %{
        "must_show" => ["匿名信"],
        "must_not_show" => ["第三人清晰正脸"],
        "reference_object_ids" => ["character:linxia", "prop:letter"]
      }
    }
  end

  defp fixture_path(name), do: Path.expand("../../support/fixtures/sources/#{name}", __DIR__)
end
