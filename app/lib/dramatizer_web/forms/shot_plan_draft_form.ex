defmodule DramatizerWeb.Forms.ShotPlanDraftForm do
  @moduledoc "Version-aware form adapter for editable ShotPlan authority drafts."

  alias DramatizerWeb.Forms.FormSupport, as: F

  @shot_list_fields ~w(story_event_ids)
  @nested_list_fields %{
    "staging" => ~w(participant_refs prop_refs),
    "audio_strategy" => ~w(dialogue_event_ids),
    "continuity" => ~w(start_state actions end_state),
    "constraints" => ~w(must_show must_not_show reference_object_ids)
  }

  def from_payload(payload) do
    payload = F.string_keys(payload || %{})

    Map.update(payload, "shots", [], fn shots ->
      Enum.map(shots, fn shot ->
        shot = encode_fields(shot, @shot_list_fields)

        Enum.reduce(@nested_list_fields, shot, fn {section, fields}, acc ->
          Map.update(acc, section, %{}, &encode_fields(&1, fields))
        end)
      end)
    end)
  end

  def cast(params, current) when is_map(params) and is_map(current) do
    params = F.string_keys(params)
    current = F.string_keys(current)

    scenes =
      F.cast_collection(
        Map.get(params, "scenes", Map.get(current, "scenes", [])),
        current["scenes"],
        &cast_scene/2
      )

    shots =
      F.cast_collection(
        Map.get(params, "shots", Map.get(current, "shots", [])),
        current["shots"],
        &cast_shot/2
      )

    payload =
      F.merge_preserving(current, %{
        "schema_version" => "shot-plan-draft-v2",
        "scenes" => scenes,
        "shots" => shots,
        "sound_strategy" => F.value(params, current, "sound_strategy", "silent_placeholder"),
        "continuity" =>
          cast_plan_continuity(params["continuity"] || %{}, current["continuity"] || %{})
      })

    errors = validate(payload)
    if errors == %{}, do: {:ok, payload}, else: {:error, errors}
  end

  def add(payload, collection, item), do: F.add(payload, collection, item)
  def remove(payload, collection, id), do: F.remove(payload, collection, id)
  def move(payload, collection, id, direction), do: F.move(payload, collection, id, direction)

  defp cast_scene(params, current) do
    F.merge_preserving(current, %{
      "id" => F.id(params, current, "SC"),
      "name" => F.value(params, current, "name"),
      "purpose" => F.value(params, current, "purpose")
    })
  end

  defp cast_shot(params, current) do
    F.merge_preserving(current, %{
      "id" => F.id(params, current, "SH"),
      "scene_id" => F.value(params, current, "scene_id"),
      "beat_id" => F.value(params, current, "beat_id"),
      "story_event_ids" => F.text_list(F.value(params, current, "story_event_ids", [])),
      "presentation_goal" => F.value(params, current, "presentation_goal"),
      "description" => F.value(params, current, "description"),
      "shot_class" => F.value(params, current, "shot_class", "medium"),
      "coverage" => F.value(params, current, "coverage", "primary"),
      "minimum_duration_ms" => duration(params, current, "minimum_duration_ms", 1_000),
      "preferred_duration_ms" => duration(params, current, "preferred_duration_ms", 2_000),
      "maximum_duration_ms" => duration(params, current, "maximum_duration_ms", 3_000),
      "timing_rationale" => F.value(params, current, "timing_rationale"),
      "camera" => cast_camera(params["camera"] || %{}, current["camera"] || %{}),
      "staging" => cast_staging(params["staging"] || %{}, current["staging"] || %{}),
      "audio_strategy" =>
        cast_audio(params["audio_strategy"] || %{}, current["audio_strategy"] || %{}),
      "continuity" => cast_continuity(params["continuity"] || %{}, current["continuity"] || %{}),
      "constraints" =>
        cast_constraints(params["constraints"] || %{}, current["constraints"] || %{})
    })
  end

  defp cast_camera(params, current) do
    F.merge_preserving(current, %{
      "shot_size" => F.value(params, current, "shot_size", "medium"),
      "angle" => F.value(params, current, "angle", "eye_level"),
      "movement" => F.value(params, current, "movement", "static"),
      "visual_focus" => F.value(params, current, "visual_focus"),
      "composition_notes" => F.value(params, current, "composition_notes"),
      "lens_intent" => F.value(params, current, "lens_intent")
    })
  end

  defp cast_staging(params, current) do
    F.merge_preserving(current, %{
      "location_ref" => F.value(params, current, "location_ref"),
      "participant_refs" => F.text_list(F.value(params, current, "participant_refs", [])),
      "prop_refs" => F.text_list(F.value(params, current, "prop_refs", [])),
      "blocking_notes" => F.value(params, current, "blocking_notes")
    })
  end

  defp cast_audio(params, current) do
    mode = F.value(params, current, "mode", "no_dialogue")

    F.merge_preserving(current, %{
      "mode" =>
        if(mode in ~w(no_dialogue narrative_dialogue voice_over), do: mode, else: "no_dialogue"),
      "dialogue_event_ids" => F.text_list(F.value(params, current, "dialogue_event_ids", [])),
      "sound_notes" => F.value(params, current, "sound_notes")
    })
  end

  defp cast_continuity(params, current) do
    F.merge_preserving(current, %{
      "start_state" => F.text_list(F.value(params, current, "start_state", [])),
      "actions" => F.text_list(F.value(params, current, "actions", [])),
      "end_state" => F.text_list(F.value(params, current, "end_state", [])),
      "relation_to_previous" => F.value(params, current, "relation_to_previous", "cut")
    })
  end

  defp cast_constraints(params, current) do
    F.merge_preserving(current, %{
      "must_show" => F.text_list(F.value(params, current, "must_show", [])),
      "must_not_show" => F.text_list(F.value(params, current, "must_not_show", [])),
      "reference_object_ids" => F.text_list(F.value(params, current, "reference_object_ids", []))
    })
  end

  defp cast_plan_continuity(params, current) do
    F.merge_preserving(current, %{
      "track" => F.value(params, current, "track", "linear"),
      "notes" => F.value(params, current, "notes")
    })
  end

  defp duration(params, current, field, default) do
    case F.integer(F.value(params, current, field, default)) do
      {:ok, value} when is_integer(value) -> value
      _other -> -1
    end
  end

  defp validate(payload) do
    scenes = payload["scenes"]
    shots = payload["shots"]
    scene_ids = MapSet.new(scenes, & &1["id"])

    errors = %{}

    errors =
      if scenes != [] and F.unique_ids?(scenes),
        do: errors,
        else: F.put_error(errors, :scenes, "场景不能为空且 ID 必须唯一")

    errors =
      if shots != [] and F.unique_ids?(shots),
        do: errors,
        else: F.put_error(errors, :shots, "镜头不能为空且 ID 必须唯一")

    Enum.reduce(shots, errors, fn shot, acc ->
      acc
      |> validate_shot_required(shot, scene_ids)
      |> validate_duration(shot)
      |> validate_constraints(shot)
    end)
  end

  defp validate_shot_required(errors, shot, scene_ids) do
    valid =
      F.required?(shot["presentation_goal"]) and F.required?(shot["description"]) and
        MapSet.member?(scene_ids, shot["scene_id"]) and
        F.required?(shot["camera"]["visual_focus"]) and
        F.required?(shot["staging"]["location_ref"])

    if valid, do: errors, else: F.put_error(errors, :shots, "镜头必填字段或场景引用无效")
  end

  defp validate_duration(errors, shot) do
    minimum = shot["minimum_duration_ms"]
    preferred = shot["preferred_duration_ms"]
    maximum = shot["maximum_duration_ms"]

    if minimum >= 250 and minimum <= preferred and preferred <= maximum,
      do: errors,
      else: F.put_error(errors, :shots, "镜头时长必须满足最小值 ≤ 建议值 ≤ 最大值")
  end

  defp validate_constraints(errors, shot) do
    constraints = shot["constraints"]

    case F.conflicts(constraints["must_show"], constraints["must_not_show"]) do
      [] -> errors
      conflicts -> F.put_error(errors, :shots, "镜头约束冲突：#{Enum.join(conflicts, "、")}")
    end
  end

  defp encode_fields(item, fields) do
    Enum.reduce(fields, item, fn field, acc ->
      Map.update(acc, field, "", fn value -> F.text_list_input(value) end)
    end)
  end
end
