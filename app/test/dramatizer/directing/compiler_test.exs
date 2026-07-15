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
               }, source_revision_ids: [source.id])

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

    frozen = first.payload["frozen_inputs"]

    assert frozen["source_revisions"] == [
             %{"id" => source.id, "content_hash" => source.content_hash, "revision" => 1}
           ]

    assert frozen["revisions"]["shot_plan"]["id"] == shot_plan.id
    assert frozen["production_profile"]["aspect_width"] == 9
    assert frozen["prompt_snapshot_ids"] == opts[:prompt_snapshot_ids]
    assert frozen["compiler_version"] == "directing-compiler-v1"
    assert frozen["template_version"] == "v1"
    assert frozen["compiler_config"] == %{"candidate_count" => 2}

    changed_opts = Keyword.put(opts, :compiler_config, %{"candidate_count" => 3})
    assert {:ok, changed} = Compiler.compile(project, inputs, changed_opts)
    refute changed.hash == first.hash

    assert {:ok, generation_revision} = Compiler.compile_revision(project, inputs, opts)
    assert generation_revision.kind == :generation_spec
    assert generation_revision.payload == first.payload
  end

  defp confirmed(project, kind, payload) do
    {:ok, draft} = Revisions.create_draft(project, kind, payload, %{"fixture" => true})
    {:ok, revision} = Revisions.confirm_draft(draft.id)
    revision
  end

  defp fixture_path(name), do: Path.expand("../../support/fixtures/sources/#{name}", __DIR__)
end
