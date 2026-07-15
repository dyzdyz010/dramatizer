defmodule DramatizerWeb.Forms.DraftFormsTest do
  use ExUnit.Case, async: true

  alias DramatizerWeb.Forms.{NarrativeDraftForm, ShotPlanDraftForm, VisualDesignDraftForm}

  test "narrative form round-trips nested business fields and preserves legacy extensions" do
    current = %{
      "legacy_extension" => %{"keep" => true},
      "episode" => %{"id" => "EP001", "legacy_episode" => "keep"},
      "scenes" => []
    }

    params = %{
      "episode" => %{"title" => "雨夜来信", "summary" => "一封旧信重启调查"},
      "scenes" => %{
        "0" => %{
          "id" => "SC001",
          "title" => "车站",
          "summary" => "收到信",
          "beats" => %{
            "0" => %{
              "id" => "BT001",
              "title" => "异样",
              "summary" => "信封没有邮戳",
              "story_event_ids" => "EV001"
            }
          }
        }
      },
      "story_events" => %{
        "0" => %{
          "id" => "EV001",
          "name" => "收到旧信",
          "description" => "林夏收到十年前写出的信",
          "subject_refs" => "character:lin, prop:letter"
        }
      }
    }

    assert {:ok, payload} = NarrativeDraftForm.cast(params, current)
    assert payload["schema_version"] == "narrative-draft-v2"
    assert hd(payload["scenes"])["title"] == "车站"
    assert hd(hd(payload["scenes"])["beats"])["story_event_ids"] == ["EV001"]
    assert payload["legacy_extension"] == %{"keep" => true}
    assert payload["episode"]["legacy_episode"] == "keep"
  end

  test "all form adapters preserve IDs and unknown fields through payload round trip" do
    visual = %{
      "schema_version" => "visual-design-draft-v2",
      "extension" => 42,
      "objects" => [
        %{
          "id" => "character:lin",
          "type" => "character",
          "name" => "林夏",
          "description" => "记者",
          "reference_required" => true,
          "legacy_object" => "keep",
          "variants" => [
            %{
              "id" => "default",
              "name" => "常服",
              "required_slots" => ["face_closeup"],
              "legacy_variant" => true
            }
          ]
        }
      ]
    }

    assert {:ok, visual_payload} =
             visual
             |> VisualDesignDraftForm.from_payload()
             |> VisualDesignDraftForm.cast(visual)

    assert visual_payload["extension"] == 42
    assert hd(visual_payload["objects"])["legacy_object"] == "keep"
    assert hd(hd(visual_payload["objects"])["variants"])["legacy_variant"]

    shot = %{
      "schema_version" => "shot-plan-draft-v2",
      "extension" => %{"keep" => true},
      "scenes" => [%{"id" => "SC001", "name" => "车站", "purpose" => "建立悬念"}],
      "shots" => [valid_shot(%{"legacy_shot" => "keep"})],
      "sound_strategy" => "dialogue_first",
      "continuity" => %{"track" => "linear", "notes" => ""}
    }

    assert {:ok, shot_payload} =
             shot
             |> ShotPlanDraftForm.from_payload()
             |> ShotPlanDraftForm.cast(shot)

    assert shot_payload["extension"] == %{"keep" => true}
    assert hd(shot_payload["shots"])["legacy_shot"] == "keep"
  end

  test "shot form rejects inverted duration bounds and conflicting constraints" do
    invalid =
      valid_shot(%{
        "minimum_duration_ms" => "3000",
        "preferred_duration_ms" => "2000",
        "maximum_duration_ms" => "1000",
        "constraints" => %{"must_show" => "旧信", "must_not_show" => "旧信"}
      })

    assert {:error, errors} =
             ShotPlanDraftForm.cast(
               %{
                 "scenes" => %{
                   "0" => %{"id" => "SC001", "name" => "车站", "purpose" => "悬念"}
                 },
                 "shots" => %{"0" => invalid}
               },
               %{}
             )

    assert errors[:shots]
  end

  test "visual form supports deterministic add, remove, and move operations" do
    payload = %{"objects" => [%{"id" => "a"}, %{"id" => "b"}]}

    added = VisualDesignDraftForm.add(payload, :objects, %{"id" => "c"})
    assert Enum.map(added["objects"], & &1["id"]) == ["a", "b", "c"]

    moved = VisualDesignDraftForm.move(added, :objects, "c", :up)
    assert Enum.map(moved["objects"], & &1["id"]) == ["a", "c", "b"]

    removed = VisualDesignDraftForm.remove(moved, :objects, "a")
    assert Enum.map(removed["objects"], & &1["id"]) == ["c", "b"]
  end

  defp valid_shot(overrides) do
    Map.merge(
      %{
        "id" => "SH001",
        "scene_id" => "SC001",
        "beat_id" => "BT001",
        "story_event_ids" => "EV001",
        "presentation_goal" => "发现旧信",
        "description" => "镜头推近信封",
        "shot_class" => "insert",
        "coverage" => "primary",
        "minimum_duration_ms" => "1000",
        "preferred_duration_ms" => "2000",
        "maximum_duration_ms" => "3000",
        "timing_rationale" => "留出识别时间",
        "camera" => %{
          "shot_size" => "close_up",
          "angle" => "eye_level",
          "movement" => "push_in",
          "visual_focus" => "letter",
          "composition_notes" => "居中",
          "lens_intent" => "压缩背景"
        },
        "staging" => %{
          "location_ref" => "location:station",
          "participant_refs" => "character:lin",
          "prop_refs" => "prop:letter",
          "blocking_notes" => "人物停步"
        },
        "audio_strategy" => %{
          "mode" => "no_dialogue",
          "dialogue_event_ids" => "",
          "sound_notes" => "雨声"
        },
        "continuity" => %{
          "start_state" => "空手",
          "actions" => "拿起旧信",
          "end_state" => "持有旧信",
          "relation_to_previous" => "match_action"
        },
        "constraints" => %{
          "must_show" => "旧信",
          "must_not_show" => "现代手机",
          "reference_object_ids" => "prop:letter"
        }
      },
      overrides
    )
  end
end
