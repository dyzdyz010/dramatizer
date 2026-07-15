defmodule Dramatizer.Timeline.RenderRecipe do
  @moduledoc "Canonical preview/formal render recipes and idempotent media export."

  alias Dramatizer.{Assets, CanonicalJSON, Projects, Repo}
  alias Dramatizer.Media.Worker
  alias Dramatizer.Timeline
  alias Dramatizer.Timeline.{RenderManifest, SRT, TimelineVersion}

  @fps 24

  def preview(%Timeline.Timeline{} = timeline) do
    clips = Timeline.list_clips(timeline) |> Enum.map(&live_clip/1)
    subtitles = Timeline.list_subtitles(timeline) |> Enum.map(&live_subtitle/1)
    duration_ms = duration(clips)

    prepare(
      timeline.project_id,
      timeline.id,
      nil,
      :preview,
      timeline.profile_snapshot,
      clips,
      subtitles,
      duration_ms
    )
  end

  def formal(%TimelineVersion{} = version) do
    prepare(
      version.project_id,
      version.timeline_id,
      version.id,
      :formal,
      version.profile_snapshot,
      version.clip_snapshot,
      version.subtitle_snapshot,
      version.duration_ms
    )
  end

  def render(%RenderManifest{id: id}) do
    manifest = Repo.get!(RenderManifest, id)

    if manifest.status == :rendered do
      {:ok, manifest}
    else
      do_render(manifest)
    end
  end

  defp prepare(
         project_id,
         timeline_id,
         timeline_version_id,
         mode,
         profile,
         clips,
         subtitles,
         duration_ms
       ) do
    {width, height} = dimensions(profile, mode)

    input_manifest = %{
      "schema_version" => 1,
      "render_mode" => Atom.to_string(mode),
      "width" => width,
      "height" => height,
      "fps" => @fps,
      "duration_ms" => duration_ms,
      "audio_mode" => "silence_placeholder",
      "subtitle_burn_in" => true,
      "clips" => clips,
      "subtitles" => subtitles,
      "srt" => SRT.encode(subtitles)
    }

    recipe_hash = CanonicalJSON.hash(input_manifest)

    %RenderManifest{}
    |> RenderManifest.create_changeset(%{
      project_id: project_id,
      timeline_id: timeline_id,
      timeline_version_id: timeline_version_id,
      render_mode: mode,
      width: width,
      height: height,
      fps: @fps,
      duration_ms: duration_ms,
      input_manifest: input_manifest,
      recipe_hash: recipe_hash
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:project_id, :render_mode, :recipe_hash]
    )

    {:ok,
     Repo.get_by!(RenderManifest,
       project_id: project_id,
       render_mode: mode,
       recipe_hash: recipe_hash
     )}
  end

  defp do_render(manifest) do
    manifest =
      manifest
      |> RenderManifest.status_changeset(%{
        status: :rendering,
        technical_qc: %{},
        error_code: nil
      })
      |> Repo.update!()

    temp_root =
      Path.join(
        System.tmp_dir!(),
        "dramatizer-render-#{manifest.id}-#{System.unique_integer([:positive])}"
      )

    output_path = Path.join(temp_root, "output.mp4")
    srt_path = Path.join(temp_root, "subtitles.srt")
    File.mkdir_p!(temp_root)

    result =
      with :ok <- File.write(srt_path, manifest.input_manifest["srt"], [:binary]),
           payload <- worker_payload(manifest, output_path, srt_path),
           {:ok, probe} <- Worker.run(:render_animatic, payload),
           {:ok, output_bytes} <- File.read(output_path),
           {:ok, srt_bytes} <- File.read(srt_path),
           project <- Projects.get_project!(manifest.project_id),
           {:ok, output_asset} <- store_output(project, manifest, output_bytes),
           {:ok, srt_asset} <- store_srt(project, manifest, srt_bytes),
           qc <- technical_qc(manifest, probe),
           {:ok, rendered} <- finish_render(manifest, output_asset.id, srt_asset.id, qc) do
        if qc["status"] == "pass" do
          {:ok, rendered}
        else
          {:error, {:technical_qc_failed, qc}}
        end
      else
        {:error, reason} -> fail_render(manifest, reason)
      end

    File.rm_rf(temp_root)
    result
  end

  defp worker_payload(manifest, output_path, srt_path) do
    manifest.input_manifest
    |> Map.take([
      "width",
      "height",
      "fps",
      "duration_ms",
      "subtitle_burn_in",
      "audio_mode"
    ])
    |> Map.put("clips", Enum.map(manifest.input_manifest["clips"], &renderable_clip/1))
    |> Map.put("output_path", output_path)
    |> Map.put("srt_path", srt_path)
    |> Map.put("ffmpeg_path", Application.fetch_env!(:dramatizer, :ffmpeg_path))
    |> Map.put("ffprobe_path", Application.fetch_env!(:dramatizer, :ffprobe_path))
  end

  defp renderable_clip(%{"asset" => %{"id" => id}} = clip) when is_binary(id) do
    asset = Assets.get_asset!(id)
    Map.put(clip, "path", Assets.absolute_path(asset))
  end

  defp renderable_clip(clip), do: Map.put(clip, "path", nil)

  defp store_output(project, manifest, bytes) do
    with {:ok, intent} <-
           Assets.create_upload_intent(project, %{
             purpose: "timeline-render",
             expected_mime: "video/mp4",
             idempotency_key: "render-mp4-#{manifest.recipe_hash}"
           }),
         {:ok, staged} <- Assets.stage_bytes(intent, bytes) do
      Assets.finalize(staged, lineage(manifest, "ffmpeg"))
    end
  end

  defp store_srt(project, manifest, bytes) do
    with {:ok, intent} <-
           Assets.create_upload_intent(project, %{
             purpose: "timeline-subtitles",
             expected_mime: "application/x-subrip",
             idempotency_key: "render-srt-#{manifest.recipe_hash}"
           }),
         {:ok, staged} <- Assets.stage_bytes(intent, bytes) do
      Assets.finalize(staged, lineage(manifest, "timeline_srt"))
    end
  end

  defp lineage(manifest, origin) do
    %{
      "origin" => origin,
      "formal" => manifest.render_mode == :formal,
      "render_manifest_id" => manifest.id,
      "timeline_id" => manifest.timeline_id,
      "timeline_version_id" => manifest.timeline_version_id,
      "recipe_hash" => manifest.recipe_hash
    }
  end

  defp technical_qc(manifest, probe) do
    checks = [
      probe["video_codec"] == "h264",
      probe["pixel_format"] == "yuv420p",
      probe["width"] == manifest.width,
      probe["height"] == manifest.height,
      probe["audio_codec"] == "aac",
      probe["audio_channels"] == 2,
      probe["audio_is_silence"] == true,
      is_integer(probe["duration_ms"]) and
        abs(probe["duration_ms"] - manifest.duration_ms) <= 150
    ]

    probe
    |> Map.put("status", if(Enum.all?(checks), do: "pass", else: "fail"))
    |> Map.put("subtitle_burn_in", manifest.input_manifest["subtitle_burn_in"])
  end

  defp finish_render(manifest, output_asset_id, srt_asset_id, qc) do
    status = if qc["status"] == "pass", do: :rendered, else: :failed

    manifest
    |> RenderManifest.status_changeset(%{
      status: status,
      output_asset_id: output_asset_id,
      srt_asset_id: srt_asset_id,
      technical_qc: qc,
      error_code: if(status == :failed, do: "technical_qc_failed")
    })
    |> Repo.update()
  end

  defp fail_render(manifest, reason) do
    code = error_code(reason)

    manifest
    |> RenderManifest.status_changeset(%{
      status: :failed,
      technical_qc: %{},
      error_code: code
    })
    |> Repo.update()

    {:error, reason}
  end

  defp error_code(%{code: code}), do: to_string(code)
  defp error_code({code, _detail}) when is_atom(code), do: Atom.to_string(code)
  defp error_code(code) when is_atom(code), do: Atom.to_string(code)
  defp error_code(_reason), do: "render_failed"

  defp live_clip(clip) do
    asset =
      if clip.asset_version_id do
        value = Assets.get_asset!(clip.asset_version_id)

        %{
          "id" => value.id,
          "blob_hash" => value.blob_hash,
          "mime_type" => value.mime_type
        }
      end

    %{
      "id" => clip.id,
      "position" => clip.position,
      "shot_id" => clip.shot_id,
      "asset" => asset,
      "placeholder" => clip.placeholder,
      "duration_ms" => clip.duration_ms,
      "motion" => Atom.to_string(clip.motion),
      "transition_after" => Atom.to_string(clip.transition_after),
      "transition_duration_ms" => clip.transition_duration_ms
    }
  end

  defp live_subtitle(cue) do
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

  defp dimensions(profile, :preview),
    do:
      {profile_value(profile, "preview_width", 540),
       profile_value(profile, "preview_height", 960)}

  defp dimensions(profile, :formal),
    do:
      {profile_value(profile, "formal_width", 1080),
       profile_value(profile, "formal_height", 1920)}

  defp profile_value(profile, key, default) do
    Map.get(profile, key) || Map.get(profile, String.to_existing_atom(key)) || default
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
end
