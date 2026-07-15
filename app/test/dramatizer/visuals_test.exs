defmodule Dramatizer.VisualsTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Assets
  alias Dramatizer.Projects
  alias Dramatizer.Revisions
  alias Dramatizer.Visuals

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(System.tmp_dir!(), "dramatizer-visuals-#{System.unique_integer([:positive])}")

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "variants receive type-specific slots and only confirmed required sets accept primary assets" do
    assert {:ok, project} = Projects.create_project(%{name: "视觉参考"})

    objects = [
      %{
        "id" => "character:lin",
        "type" => "character",
        "recurring" => true,
        "key" => true,
        "variants" => [%{"id" => "default"}, %{"id" => "raincoat"}]
      },
      %{
        "id" => "location:station",
        "type" => "location",
        "recurring" => false,
        "key" => true,
        "variants" => [%{"id" => "night"}]
      },
      %{
        "id" => "prop:letter",
        "type" => "prop",
        "recurring" => false,
        "key" => false,
        "variants" => [%{"id" => "default"}]
      }
    ]

    assert {:ok, design_draft} = Visuals.create_design_draft(project, nil, objects)
    character = Enum.find(design_draft.payload["objects"], &(&1["id"] == "character:lin"))
    location = Enum.find(design_draft.payload["objects"], &(&1["id"] == "location:station"))
    prop = Enum.find(design_draft.payload["objects"], &(&1["id"] == "prop:letter"))

    assert character["reference_required"]
    assert Enum.map(character["variants"], & &1["id"]) == ["default", "raincoat"]

    assert hd(character["variants"])["required_slots"] ==
             ~w(face_closeup three_quarter_full expression_features)

    assert location["reference_required"]

    assert hd(location["variants"])["required_slots"] ==
             ~w(spatial_wide primary_direction key_lighting)

    refute prop["reference_required"]
    assert hd(prop["variants"])["required_slots"] == ~w(overall key_detail_state)

    assert {:error, {:unconfirmed_visual_design, _id}} =
             Visuals.create_reference_set_draft(project, design_draft, %{})

    assert {:ok, visual_revision} = Revisions.confirm_draft(design_draft.id)
    assert {:ok, asset} = upload_asset(project)

    assert {:error, {:missing_primary_assets, missing}} =
             Visuals.create_reference_set_draft(project, visual_revision, %{})

    assert length(missing) == 9

    assignments =
      for object <- visual_revision.payload["objects"],
          object["reference_required"],
          variant <- object["variants"],
          slot <- variant["required_slots"],
          into: %{} do
        {"#{object["id"]}/#{variant["id"]}/#{slot}", asset.id}
      end

    assert {:ok, reference_draft} =
             Visuals.create_reference_set_draft(project, visual_revision, assignments)

    assert reference_draft.kind == :reference_set
    assert map_size(reference_draft.payload["primary_assets"]) == 9

    assert Enum.all?(reference_draft.payload["primary_assets"], fn {_slot, id} ->
             id == asset.id
           end)
  end

  test "explicit reference decisions and custom required slots survive normalization" do
    assert {:ok, project} = Projects.create_project(%{name: "显式参考策略"})

    objects = [
      %{
        "id" => "character:guest",
        "type" => "character",
        "name" => "过场人物",
        "recurring" => true,
        "key" => true,
        "reference_required" => false,
        "variants" => [
          %{
            "id" => "rain",
            "name" => "雨中",
            "required_slots" => ["custom_silhouette"]
          }
        ]
      }
    ]

    assert {:ok, draft} = Visuals.create_design_draft(project, nil, objects)
    object = hd(draft.payload["objects"])
    refute object["reference_required"]
    assert hd(object["variants"])["required_slots"] == ["custom_silhouette"]
  end

  defp upload_asset(project) do
    {:ok, intent} =
      Assets.create_upload_intent(project, %{
        purpose: "reference",
        expected_mime: "image/png",
        idempotency_key: "visuals-test"
      })

    {:ok, staged} = Assets.stage_bytes(intent, @png)
    Assets.finalize(staged, %{"origin" => "upload"})
  end
end
