defmodule Dramatizer.TestFixtures.Timeline do
  alias Dramatizer.Assets
  alias Dramatizer.Generation
  alias Dramatizer.Quality
  alias Dramatizer.Revisions

  def confirmed(project, kind, payload) do
    {:ok, draft} = Revisions.create_draft(project, kind, payload, %{"fixture" => true})
    {:ok, revision} = Revisions.confirm_draft(draft.id)
    revision
  end

  def selected_image(project, shot_id, slot_key, width \\ 540, height \\ 960) do
    {:ok, generated} =
      Dramatizer.Media.Worker.run(:generate_fake_image, %{
        "width" => width,
        "height" => height,
        "seed" => shot_id
      })

    {:ok, intent} =
      Assets.create_upload_intent(project, %{
        purpose: "timeline-shot",
        expected_mime: "image/png",
        idempotency_key: "timeline-#{shot_id}-#{width}x#{height}"
      })

    {:ok, staged} = Assets.stage_bytes(intent, Base.decode64!(generated["png_base64"]))

    {:ok, spec} =
      Generation.create_spec(project, %{
        kind: "shot_keyframe",
        formal: true,
        payload: %{"shot_id" => shot_id, "aspect_width" => 9, "aspect_height" => 16}
      })

    {:ok, asset} =
      Assets.finalize(staged, %{
        "origin" => "fixture",
        "formal" => true,
        "generation_spec_id" => spec.id
      })

    {:ok, _technical} = Quality.run_technical(asset, spec)
    {:ok, selection} = Quality.select(project, slot_key, spec, asset)
    {spec, asset, selection}
  end

  def narrative_payload do
    %{
      "episode_id" => "E001",
      "dialogue_events" => [
        %{
          "id" => "D001",
          "shot_id" => "S001",
          "text" => "你终于来了。雨还没有停？",
          "start_ms" => 100,
          "end_ms" => 1800,
          "style" => %{"position" => "safe_bottom"}
        },
        %{
          "id" => "D002",
          "shot_id" => "S002",
          "text" => "这封信不是我写的。",
          "start_ms" => 2100,
          "end_ms" => 3600,
          "style" => %{"position" => "safe_bottom"}
        }
      ]
    }
  end

  def shot_plan_payload do
    %{
      "scenes" => [%{"id" => "SC001"}],
      "shots" => [
        %{
          "id" => "S001",
          "scene_id" => "SC001",
          "minimum_duration_ms" => 1500,
          "preferred_duration_ms" => 2000,
          "maximum_duration_ms" => 2800,
          "camera" => "push_in"
        },
        %{
          "id" => "S002",
          "scene_id" => "SC001",
          "minimum_duration_ms" => 1200,
          "preferred_duration_ms" => 1800,
          "maximum_duration_ms" => 2400,
          "camera" => "pan_left"
        },
        %{
          "id" => "S003",
          "scene_id" => "SC001",
          "minimum_duration_ms" => 1000,
          "preferred_duration_ms" => 1600,
          "maximum_duration_ms" => 2200,
          "camera" => "static"
        }
      ],
      "audio_strategy" => "silence_placeholder"
    }
  end
end
