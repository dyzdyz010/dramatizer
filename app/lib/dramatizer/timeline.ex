defmodule Dramatizer.Timeline do
  @moduledoc "Editable Timeline drafts and immutable TimelineVersion freezes."

  import Ecto.Query

  alias Dramatizer.Assets
  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Changes.StaleRecord
  alias Dramatizer.Projects.Project
  alias Dramatizer.Quality.SelectionDecision
  alias Dramatizer.Repo
  alias Dramatizer.Revisions.Revision

  alias Dramatizer.Timeline.{
    Clip,
    RenderManifest,
    SubtitleCue,
    Timeline,
    TimelineVersion
  }

  def create(
        %Project{id: project_id},
        %Revision{project_id: project_id, kind: :narrative} = narrative,
        %Revision{project_id: project_id, kind: :shot_plan} = shot_plan,
        selections_by_shot
      )
      when is_map(selections_by_shot) do
    Repo.transaction(fn ->
      timeline =
        %Timeline{}
        |> Timeline.create_changeset(%{
          project_id: project_id,
          narrative_revision_id: narrative.id,
          shot_plan_revision_id: shot_plan.id,
          profile_snapshot: stringify(shot_plan.profile_snapshot)
        })
        |> Repo.insert!()

      shot_plan.payload
      |> Map.get("shots", [])
      |> Enum.with_index(1)
      |> Enum.each(fn {shot, position} ->
        selection = Map.get(selections_by_shot, shot["id"])
        insert_clip!(timeline, shot, position, selection)
      end)

      narrative.payload
      |> Map.get("dialogue_events", [])
      |> subtitle_attrs(narrative.id)
      |> Enum.with_index(1)
      |> Enum.each(fn {attrs, position} ->
        %SubtitleCue{}
        |> SubtitleCue.create_changeset(
          attrs
          |> Map.put(:timeline_id, timeline.id)
          |> Map.put(:position, position)
        )
        |> Repo.insert!()
      end)

      timeline
    end)
    |> unwrap()
  end

  def create(%Project{}, %Revision{}, %Revision{}, _selections),
    do: {:error, :confirmed_timeline_inputs_required}

  def list_clips(%Timeline{id: id}) do
    Repo.all(from clip in Clip, where: clip.timeline_id == ^id, order_by: [asc: clip.position])
  end

  def list_subtitles(%Timeline{id: id}) do
    Repo.all(
      from cue in SubtitleCue,
        where: cue.timeline_id == ^id,
        order_by: [asc: cue.position]
    )
  end

  def set_duration(%Clip{} = clip, duration_ms, opts \\ [])
      when is_integer(duration_ms) and duration_ms > 0 do
    duration =
      if Keyword.get(opts, :snap, false) do
        [clip.minimum_duration_ms, clip.preferred_duration_ms, clip.maximum_duration_ms]
        |> Enum.min_by(&abs(&1 - duration_ms))
      else
        duration_ms
      end

    warning = duration < clip.minimum_duration_ms or duration > clip.maximum_duration_ms

    clip
    |> Clip.edit_changeset(%{duration_ms: duration, duration_warning: warning})
    |> Repo.update()
  end

  def set_motion(%Clip{} = clip, motion) do
    if motion in Clip.motions() do
      clip |> Clip.edit_changeset(%{motion: motion}) |> Repo.update()
    else
      {:error, :unsupported_motion}
    end
  end

  def set_transition(clip, transition, duration_ms \\ 0)

  def set_transition(%Clip{} = clip, :hard_cut, _duration_ms) do
    clip
    |> Clip.edit_changeset(%{transition_after: :hard_cut, transition_duration_ms: 0})
    |> Repo.update()
  end

  def set_transition(%Clip{} = clip, :cross_dissolve, duration_ms)
      when is_integer(duration_ms) and duration_ms > 0 do
    maximum = min(1_000, div(clip.duration_ms, 2))

    if duration_ms <= maximum do
      clip
      |> Clip.edit_changeset(%{
        transition_after: :cross_dissolve,
        transition_duration_ms: duration_ms
      })
      |> Repo.update()
    else
      {:error, :transition_duration_out_of_bounds}
    end
  end

  def set_transition(%Clip{}, _transition, _duration),
    do: {:error, :transition_duration_out_of_bounds}

  def move_clip(%Timeline{} = timeline, clip_id, new_position)
      when is_integer(new_position) and new_position > 0 do
    clips = list_clips(timeline)

    case Enum.find(clips, &(&1.id == clip_id)) do
      nil ->
        {:error, :clip_not_found}

      selected ->
        reordered =
          clips
          |> Enum.reject(&(&1.id == clip_id))
          |> List.insert_at(min(new_position - 1, length(clips) - 1), selected)

        persist_positions(reordered)
        {:ok, timeline}
    end
  end

  def add_clip(%Timeline{} = timeline, attrs) do
    position =
      min(
        Map.get(attrs, :position, length(list_clips(timeline)) + 1),
        length(list_clips(timeline)) + 1
      )

    Repo.update_all(
      from(clip in Clip,
        where: clip.timeline_id == ^timeline.id and clip.position >= ^position
      ),
      inc: [position: 1]
    )

    duration = Map.fetch!(attrs, :duration_ms)

    %Clip{}
    |> Clip.create_changeset(%{
      timeline_id: timeline.id,
      position: position,
      shot_id: Map.fetch!(attrs, :shot_id),
      placeholder: true,
      minimum_duration_ms: Map.get(attrs, :minimum_duration_ms, duration),
      preferred_duration_ms: Map.get(attrs, :preferred_duration_ms, duration),
      maximum_duration_ms: Map.get(attrs, :maximum_duration_ms, duration),
      duration_ms: duration,
      duration_warning: false,
      motion: Map.get(attrs, :motion, :static),
      transition_after: :hard_cut,
      transition_duration_ms: 0
    })
    |> Repo.insert()
  end

  def remove_clip(
        %Timeline{id: timeline_id} = timeline,
        %Clip{timeline_id: timeline_id} = clip
      ) do
    Repo.delete!(clip)
    timeline |> list_clips() |> persist_positions()
    {:ok, timeline}
  end

  def replace_clip(%Clip{} = clip, %SelectionDecision{status: :active} = selection) do
    clip
    |> Clip.edit_changeset(%{
      selection_decision_id: selection.id,
      asset_version_id: selection.asset_version_id,
      placeholder: false
    })
    |> Repo.update()
  end

  def replace_clip(%Clip{}, %SelectionDecision{}), do: {:error, :selection_not_active}

  def update_subtitle(%SubtitleCue{} = cue, attrs) do
    cue |> SubtitleCue.edit_changeset(attrs) |> Repo.update()
  end

  def freeze(%Timeline{} = timeline) do
    clips = list_clips(timeline)
    selection_ids = clips |> Enum.map(& &1.selection_decision_id) |> Enum.reject(&is_nil/1)

    unresolved =
      Repo.all(
        from record in StaleRecord,
          where:
            record.subject_type == "selection_decision" and
              record.subject_id in ^selection_ids and record.resolution == :unresolved,
          select: record.subject_id
      )
      |> Enum.uniq()

    if unresolved == [] do
      cues = list_subtitles(timeline)
      clip_snapshot = Enum.map(clips, &clip_snapshot/1)
      subtitle_snapshot = Enum.map(cues, &subtitle_snapshot/1)
      duration_ms = duration(clip_snapshot)
      next_version = next_version(timeline.id)

      payload = %{
        "timeline_id" => timeline.id,
        "version" => next_version,
        "narrative_revision_id" => timeline.narrative_revision_id,
        "shot_plan_revision_id" => timeline.shot_plan_revision_id,
        "profile_snapshot" => timeline.profile_snapshot,
        "clips" => clip_snapshot,
        "subtitles" => subtitle_snapshot,
        "duration_ms" => duration_ms
      }

      %TimelineVersion{}
      |> TimelineVersion.create_changeset(%{
        project_id: timeline.project_id,
        timeline_id: timeline.id,
        version: next_version,
        narrative_revision_id: timeline.narrative_revision_id,
        shot_plan_revision_id: timeline.shot_plan_revision_id,
        profile_snapshot: timeline.profile_snapshot,
        clip_snapshot: clip_snapshot,
        subtitle_snapshot: subtitle_snapshot,
        duration_ms: duration_ms,
        content_hash: CanonicalJSON.hash(payload)
      })
      |> Repo.insert()
    else
      {:error, {:unresolved_stale, unresolved}}
    end
  end

  def create_preview_manifest(%Timeline{} = timeline) do
    Dramatizer.Timeline.RenderRecipe.preview(timeline)
  end

  def render(%RenderManifest{} = manifest) do
    Dramatizer.Timeline.RenderRecipe.render(manifest)
  end

  defp insert_clip!(timeline, shot, position, selection) do
    minimum = shot["minimum_duration_ms"] || shot["preferred_duration_ms"] || 1_000
    preferred = shot["preferred_duration_ms"] || minimum
    maximum = shot["maximum_duration_ms"] || preferred
    active_selection = formal_selection?(selection)

    %Clip{}
    |> Clip.create_changeset(%{
      timeline_id: timeline.id,
      position: position,
      shot_id: shot["id"],
      selection_decision_id: if(active_selection, do: selection.id),
      asset_version_id: if(active_selection, do: selection.asset_version_id),
      placeholder: not active_selection,
      minimum_duration_ms: minimum,
      preferred_duration_ms: preferred,
      maximum_duration_ms: maximum,
      duration_ms: preferred,
      duration_warning: false,
      motion: motion_from_camera(shot["camera"]),
      transition_after: :hard_cut,
      transition_duration_ms: 0
    })
    |> Repo.insert!()
  end

  defp formal_selection?(%SelectionDecision{status: :active, generation_spec_id: spec_id}) do
    case Repo.get(Dramatizer.Generation.GenerationSpec, spec_id) do
      %Dramatizer.Generation.GenerationSpec{formal: true} -> true
      _ -> false
    end
  end

  defp formal_selection?(_selection), do: false

  defp subtitle_attrs(events, narrative_revision_id) do
    Enum.flat_map(events, fn event ->
      sentences =
        ~r/[^。！？!?]+[。！？!?]?/u
        |> Regex.scan(event["text"] || "")
        |> List.flatten()
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      count = max(1, length(sentences))
      start_ms = event["start_ms"] || 0
      end_ms = event["end_ms"] || start_ms + 1_000
      step = div(end_ms - start_ms, count)

      sentences
      |> Enum.with_index()
      |> Enum.map(fn {sentence, index} ->
        %{
          text: sentence,
          start_ms: start_ms + step * index,
          end_ms: if(index == count - 1, do: end_ms, else: start_ms + step * (index + 1)),
          style: event["style"] || %{"position" => "safe_bottom"},
          narrative_revision_id: narrative_revision_id,
          source_event_id: event["id"]
        }
      end)
    end)
  end

  defp motion_from_camera("push_in"), do: :push_in
  defp motion_from_camera("pull_out"), do: :pull_out
  defp motion_from_camera("pan_left"), do: :pan_left
  defp motion_from_camera("pan_right"), do: :pan_right
  defp motion_from_camera("pan_up"), do: :pan_up
  defp motion_from_camera("pan_down"), do: :pan_down

  defp motion_from_camera(_value), do: :static

  defp persist_positions(clips) do
    clips
    |> Enum.with_index(1)
    |> Enum.each(fn {clip, position} ->
      clip |> Clip.edit_changeset(%{position: position}) |> Repo.update!()
    end)
  end

  defp clip_snapshot(clip) do
    asset =
      if clip.asset_version_id do
        asset = Assets.get_asset!(clip.asset_version_id)
        %{"id" => asset.id, "blob_hash" => asset.blob_hash, "mime_type" => asset.mime_type}
      end

    %{
      "id" => clip.id,
      "position" => clip.position,
      "shot_id" => clip.shot_id,
      "selection_decision_id" => clip.selection_decision_id,
      "asset" => asset,
      "placeholder" => clip.placeholder,
      "minimum_duration_ms" => clip.minimum_duration_ms,
      "preferred_duration_ms" => clip.preferred_duration_ms,
      "maximum_duration_ms" => clip.maximum_duration_ms,
      "duration_ms" => clip.duration_ms,
      "duration_warning" => clip.duration_warning,
      "motion" => Atom.to_string(clip.motion),
      "transition_after" => Atom.to_string(clip.transition_after),
      "transition_duration_ms" => clip.transition_duration_ms
    }
  end

  defp subtitle_snapshot(cue) do
    %{
      "id" => cue.id,
      "position" => cue.position,
      "text" => cue.text,
      "start_ms" => cue.start_ms,
      "end_ms" => cue.end_ms,
      "style" => cue.style,
      "narrative_revision_id" => cue.narrative_revision_id,
      "source_event_id" => cue.source_event_id
    }
  end

  defp duration(clips) do
    total = Enum.sum(Enum.map(clips, & &1["duration_ms"]))

    overlap =
      clips
      |> Enum.drop(-1)
      |> Enum.filter(&(&1["transition_after"] == "cross_dissolve"))
      |> Enum.map(& &1["transition_duration_ms"])
      |> Enum.sum()

    total - overlap
  end

  defp next_version(timeline_id) do
    (Repo.one(
       from version in TimelineVersion,
         where: version.timeline_id == ^timeline_id,
         select: max(version.version)
     ) || 0) + 1
  end

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when value in [true, false, nil], do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}
end
