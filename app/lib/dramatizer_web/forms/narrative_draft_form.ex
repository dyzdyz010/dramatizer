defmodule DramatizerWeb.Forms.NarrativeDraftForm do
  @moduledoc "Version-aware form adapter for editable Narrative authority drafts."

  alias DramatizerWeb.Forms.FormSupport, as: F

  @semantics ~w(source_grounded inferred creative)
  @profile_fields ~w(aspect_width aspect_height duration_min_seconds duration_max_seconds shot_min shot_max)

  def from_payload(payload) do
    payload = F.string_keys(payload || %{})

    payload
    |> Map.update("scenes", [], fn scenes ->
      Enum.map(scenes, fn scene ->
        Map.update(scene, "beats", [], fn beats ->
          Enum.map(
            beats,
            &Map.update(&1, "story_event_ids", "", fn value -> F.text_list_input(value) end)
          )
        end)
      end)
    end)
    |> map_list_input("story_events", "subject_refs")
  end

  def cast(params, current) when is_map(params) and is_map(current) do
    params = F.string_keys(params)
    current = F.string_keys(current)

    episode = cast_episode(Map.get(params, "episode", %{}), Map.get(current, "episode", %{}))

    scenes =
      cast_scenes(Map.get(params, "scenes", Map.get(current, "scenes", [])), current["scenes"])

    story_events =
      F.cast_collection(
        Map.get(params, "story_events", Map.get(current, "story_events", [])),
        current["story_events"],
        &cast_story_event/2
      )

    dialogue_events =
      F.cast_collection(
        Map.get(params, "dialogue_events", Map.get(current, "dialogue_events", [])),
        current["dialogue_events"],
        &cast_dialogue_event/2
      )

    dependencies =
      F.cast_collection(
        Map.get(params, "dependencies", Map.get(current, "dependencies", [])),
        current["dependencies"],
        &cast_dependency/2
      )

    conflicts =
      F.cast_collection(
        Map.get(params, "conflicts", Map.get(current, "conflicts", [])),
        current["conflicts"],
        &cast_conflict/2
      )

    {profile, profile_errors} =
      cast_profile(
        Map.get(params, "production_profile_override", %{}),
        Map.get(current, "production_profile_override", %{})
      )

    payload =
      F.merge_preserving(current, %{
        "schema_version" => "narrative-draft-v2",
        "episode" => episode,
        "scenes" => scenes,
        "story_events" => story_events,
        "dialogue_events" => dialogue_events,
        "dependencies" => dependencies,
        "conflicts" => conflicts,
        "production_profile_override" => profile
      })

    errors = validate(payload, profile_errors)
    if errors == %{}, do: {:ok, payload}, else: {:error, errors}
  end

  def add(payload, "beats:" <> scene_id, item),
    do: update_scene_collection(payload, scene_id, &F.add(&1, "beats", item))

  def add(payload, collection, item), do: F.add(payload, collection, item)

  def remove(payload, "beats:" <> scene_id, id),
    do: update_scene_collection(payload, scene_id, &F.remove(&1, "beats", id))

  def remove(payload, collection, id), do: F.remove(payload, collection, id)

  def move(payload, "beats:" <> scene_id, id, direction),
    do: update_scene_collection(payload, scene_id, &F.move(&1, "beats", id, direction))

  def move(payload, collection, id, direction), do: F.move(payload, collection, id, direction)

  defp cast_episode(params, current) do
    summary = F.value(params, current, "summary")
    title = F.value(params, current, "title")

    F.merge_preserving(current, %{
      "id" => F.id(params, current, "EP"),
      "title" => title,
      "logline" => F.value(params, current, "logline", summary),
      "summary" => summary,
      "opening_hook" => F.value(params, current, "opening_hook"),
      "central_conflict" => F.value(params, current, "central_conflict", summary),
      "ending_hook" => F.value(params, current, "ending_hook")
    })
  end

  defp cast_scenes(params, current) do
    F.cast_collection(params, current, fn scene, old_scene ->
      summary = F.value(scene, old_scene, "summary")

      beats =
        F.cast_collection(
          Map.get(scene, "beats", Map.get(old_scene, "beats", [])),
          old_scene["beats"],
          fn beat, old_beat ->
            beat_summary = F.value(beat, old_beat, "summary")

            F.merge_preserving(old_beat, %{
              "id" => F.id(beat, old_beat, "BT"),
              "title" => F.value(beat, old_beat, "title"),
              "goal" => F.value(beat, old_beat, "goal", beat_summary),
              "summary" => beat_summary,
              "story_event_ids" => F.text_list(F.value(beat, old_beat, "story_event_ids", []))
            })
          end
        )

      F.merge_preserving(old_scene, %{
        "id" => F.id(scene, old_scene, "SC"),
        "title" => F.value(scene, old_scene, "title"),
        "location_ref" => F.value(scene, old_scene, "location_ref", "location:unspecified"),
        "time_of_day" => F.value(scene, old_scene, "time_of_day", "unspecified"),
        "goal" => F.value(scene, old_scene, "goal", summary),
        "summary" => summary,
        "source_semantics" => semantics(F.value(scene, old_scene, "source_semantics")),
        "beats" => beats
      })
    end)
  end

  defp cast_story_event(params, current) do
    F.merge_preserving(current, %{
      "id" => F.id(params, current, "EV"),
      "name" => F.value(params, current, "name"),
      "description" => F.value(params, current, "description"),
      "subject_refs" => F.text_list(F.value(params, current, "subject_refs", [])),
      "source_semantics" => semantics(F.value(params, current, "source_semantics"))
    })
  end

  defp cast_dialogue_event(params, current) do
    F.merge_preserving(current, %{
      "id" => F.id(params, current, "DL"),
      "speaker_ref" => F.value(params, current, "speaker_ref"),
      "text" => F.value(params, current, "text"),
      "scene_id" => F.value(params, current, "scene_id"),
      "beat_id" => F.value(params, current, "beat_id"),
      "story_event_id" => F.value(params, current, "story_event_id"),
      "source_semantics" => semantics(F.value(params, current, "source_semantics")),
      "start_ms" => parsed_integer(F.value(params, current, "start_ms", 0), 0),
      "end_ms" => parsed_integer(F.value(params, current, "end_ms", 1), 1)
    })
  end

  defp cast_dependency(params, current) do
    F.merge_preserving(current, %{
      "id" => F.id(params, current, "DP"),
      "kind" => F.value(params, current, "kind", "other"),
      "name" => F.value(params, current, "name"),
      "source_semantics" => semantics(F.value(params, current, "source_semantics"))
    })
  end

  defp cast_conflict(params, current) do
    severity = F.value(params, current, "severity", "warning")

    F.merge_preserving(current, %{
      "id" => F.id(params, current, "CF"),
      "description" => F.value(params, current, "description"),
      "severity" => if(severity in ~w(info warning blocking), do: severity, else: "warning")
    })
  end

  defp cast_profile(params, current) do
    Enum.reduce(@profile_fields, {%{}, %{}}, fn field, {profile, errors} ->
      value = F.value(params, current, field, nil)

      case F.integer(value) do
        {:ok, parsed} ->
          {Map.put(profile, field, parsed), errors}

        :error ->
          {Map.put(profile, field, nil),
           F.put_error(errors, :production_profile, "#{field} 必须是整数")}
      end
    end)
  end

  defp validate(payload, errors) do
    errors
    |> require_episode(payload["episode"])
    |> validate_collection_ids(:scenes, payload["scenes"])
    |> validate_collection_ids(:story_events, payload["story_events"])
    |> validate_collection_ids(:dialogue_events, payload["dialogue_events"])
    |> validate_beats(payload["scenes"])
    |> validate_dialogue_timing(payload["dialogue_events"])
    |> validate_profile(payload["production_profile_override"])
  end

  defp require_episode(errors, episode) do
    if F.required?(episode["title"]) and F.required?(episode["summary"]),
      do: errors,
      else: F.put_error(errors, :episode, "标题和梗概不能为空")
  end

  defp validate_collection_ids(errors, key, items) do
    if F.unique_ids?(items), do: errors, else: F.put_error(errors, key, "ID 不能为空且必须唯一")
  end

  defp validate_beats(errors, scenes) do
    if Enum.all?(scenes, &F.unique_ids?(&1["beats"] || [])),
      do: errors,
      else: F.put_error(errors, :scenes, "同一场景中的节拍 ID 必须唯一")
  end

  defp validate_dialogue_timing(errors, dialogue_events) do
    if Enum.all?(dialogue_events, &(&1["start_ms"] >= 0 and &1["end_ms"] > &1["start_ms"])),
      do: errors,
      else: F.put_error(errors, :dialogue_events, "对白结束时间必须晚于开始时间")
  end

  defp validate_profile(errors, profile) do
    valid =
      ordered?(profile["duration_min_seconds"], profile["duration_max_seconds"]) and
        ordered?(profile["shot_min"], profile["shot_max"])

    if valid, do: errors, else: F.put_error(errors, :production_profile, "最小值不能大于最大值")
  end

  defp ordered?(nil, _maximum), do: true
  defp ordered?(_minimum, nil), do: true
  defp ordered?(minimum, maximum), do: minimum <= maximum

  defp semantics(value) when value in @semantics, do: value
  defp semantics(_value), do: "source_grounded"

  defp parsed_integer(value, default) do
    case F.integer(value) do
      {:ok, nil} -> default
      {:ok, parsed} -> parsed
      :error -> default
    end
  end

  defp map_list_input(payload, collection, field) do
    Map.update(payload, collection, [], fn items ->
      Enum.map(items, &Map.update(&1, field, "", fn value -> F.text_list_input(value) end))
    end)
  end

  defp update_scene_collection(payload, scene_id, updater) do
    Map.update(F.string_keys(payload), "scenes", [], fn scenes ->
      Enum.map(scenes, fn scene ->
        if scene["id"] == scene_id, do: updater.(scene), else: scene
      end)
    end)
  end
end
