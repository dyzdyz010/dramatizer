defmodule Dramatizer.Directing.Compiler do
  @moduledoc "Pure deterministic ShotPlanRevision to GenerationSpecRevision compiler."

  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Generation.ConfigResolver
  alias Dramatizer.Projects
  alias Dramatizer.Projects.Project
  alias Dramatizer.Repo
  alias Dramatizer.Revisions
  alias Dramatizer.Revisions.{Draft, Revision}
  alias Dramatizer.Sources.SourceRevision

  @compiler_version "directing-compiler-v2"
  @template_version "v1"
  @revision_kinds %{
    narrative: :narrative,
    visual_design: :visual_design,
    reference_set: :reference_set,
    shot_plan: :shot_plan
  }

  def compile(%Project{} = project, inputs, opts \\ []) when is_map(inputs) do
    with :ok <- validate_inputs(project, inputs),
         {:ok, sources} <- source_summaries(project, Keyword.get(opts, :source_revision_ids, [])) do
      profile =
        project
        |> Projects.profile_snapshot(Keyword.get(opts, :episode_override, %{}))
        |> stringify()

      compiler_config = opts |> Keyword.get(:compiler_config, %{}) |> stringify()
      templates = template_snapshots()
      image_generation = image_generation_snapshot(project)

      revision_summaries =
        Map.new(@revision_kinds, fn {key, _kind} ->
          revision = Map.fetch!(inputs, key)
          {Atom.to_string(key), revision_summary(revision)}
        end)

      dependencies = %{
        "narrative_revision_id" => inputs.narrative.id,
        "visual_design_revision_id" => inputs.visual_design.id,
        "reference_set_revision_id" => inputs.reference_set.id,
        "shot_plan_revision_id" => inputs.shot_plan.id
      }

      specs =
        Enum.map(inputs.shot_plan.payload["shots"], fn shot ->
          render_shot_spec(shot, profile, dependencies, image_generation)
        end)

      payload = %{
        "schema_version" => "generation-spec-revision-v1",
        "frozen_inputs" => %{
          "source_revisions" => sources,
          "revisions" => revision_summaries,
          "production_profile" => profile,
          "image_generation" => image_generation,
          "prompt_snapshot_ids" => Keyword.get(opts, :prompt_snapshot_ids, []),
          "compiler_version" => @compiler_version,
          "template_version" => @template_version,
          "template_hashes" => templates,
          "compiler_config" => compiler_config
        },
        "specs" => specs
      }

      canonical = CanonicalJSON.encode(payload)

      {:ok,
       %{
         payload: payload,
         canonical_json: canonical,
         hash: CanonicalJSON.hash_bytes(canonical)
       }}
    end
  end

  def compile_revision(%Project{} = project, inputs, opts \\ []) do
    with {:ok, compiled} <- compile(project, inputs, opts),
         {:ok, draft} <-
           Revisions.create_draft(project, :generation_spec, compiled.payload, %{
             "origin" => "deterministic_compiler",
             "compiler_version" => @compiler_version,
             "compiled_hash" => compiled.hash
           }) do
      Revisions.confirm_draft(draft.id)
    end
  end

  defp validate_inputs(project, inputs) do
    Enum.reduce_while(@revision_kinds, :ok, fn {key, expected_kind}, :ok ->
      case Map.get(inputs, key) do
        %Revision{project_id: project_id, kind: ^expected_kind}
        when project_id == project.id ->
          {:cont, :ok}

        %Draft{kind: :shot_plan} when key == :shot_plan ->
          {:halt, {:error, :unconfirmed_shot_plan}}

        _ ->
          {:halt, {:error, {:invalid_compiler_input, key}}}
      end
    end)
  end

  defp source_summaries(project, source_revision_ids) do
    Enum.reduce_while(source_revision_ids, {:ok, []}, fn id, {:ok, summaries} ->
      case Repo.get(SourceRevision, id) do
        %SourceRevision{project_id: project_id} = revision when project_id == project.id ->
          summary = %{
            "id" => revision.id,
            "revision" => revision.revision,
            "content_hash" => revision.content_hash
          }

          {:cont, {:ok, summaries ++ [summary]}}

        _ ->
          {:halt, {:error, {:invalid_source_revision, id}}}
      end
    end)
  end

  defp revision_summary(revision) do
    %{
      "id" => revision.id,
      "revision" => revision.revision,
      "content_hash" => revision.content_hash
    }
  end

  defp render_shot_spec(shot, profile, dependencies, image_generation) do
    compiled_payload = compiled_shot_payload(shot, profile, dependencies, image_generation)

    template_path("shot_keyframe.json.eex")
    |> EEx.eval_file(
      shot: shot,
      compiled_payload: compiled_payload
    )
    |> Jason.decode!()
  end

  defp compiled_shot_payload(shot, profile, dependencies, image_generation) do
    camera_authority = normalize_camera(shot["camera"])
    constraints = normalize_constraints(shot)

    %{
      "shot" => shot,
      "scene_id" => shot["scene_id"],
      "beat_id" => shot["beat_id"],
      "story_event_ids" => shot["story_event_ids"] || [],
      "presentation_goal" =>
        shot["presentation_goal"] || shot["action"] || shot["description"] || "",
      "description" => shot["description"] || shot["action"] || "",
      "shot_class" => shot["shot_class"] || "legacy",
      "coverage" => shot["coverage"] || "primary",
      "minimum_duration_ms" =>
        shot["minimum_duration_ms"] || shot["preferred_duration_ms"] || 1_000,
      "preferred_duration_ms" => shot["preferred_duration_ms"] || 1_000,
      "maximum_duration_ms" =>
        shot["maximum_duration_ms"] || shot["preferred_duration_ms"] || 1_000,
      "camera" => camera_authority["movement"],
      "camera_authority" => camera_authority,
      "staging" => shot["staging"] || %{},
      "audio_strategy" => shot["audio_strategy"] || %{"mode" => "no_dialogue"},
      "continuity" => shot["continuity"] || %{},
      "must_show" => constraints["must_show"],
      "must_not_show" => constraints["must_not_show"],
      "reference_object_ids" => constraints["reference_object_ids"],
      "width" => image_generation["width"],
      "height" => image_generation["height"],
      "aspect_width" => image_generation["width"],
      "aspect_height" => image_generation["height"],
      "timeline_aspect_width" => profile["aspect_width"],
      "timeline_aspect_height" => profile["aspect_height"],
      "dependencies" => dependencies
    }
  end

  defp normalize_camera(camera) when is_map(camera) do
    camera
    |> stringify()
    |> Map.put_new("movement", "static")
  end

  defp normalize_camera(camera) when is_binary(camera), do: %{"movement" => camera}
  defp normalize_camera(_camera), do: %{"movement" => "static"}

  defp normalize_constraints(shot) do
    constraints = stringify(shot["constraints"] || %{})

    %{
      "must_show" => constraints["must_show"] || shot["must_include"] || [],
      "must_not_show" => constraints["must_not_show"] || shot["must_forbid"] || [],
      "reference_object_ids" => constraints["reference_object_ids"] || []
    }
  end

  defp image_generation_snapshot(project) do
    config = ConfigResolver.resolve(:shot_keyframe, project)
    size = config.params["size"]
    {width, height} = parse_size!(size)

    values = %{
      "adapter" => config.adapter,
      "model" => config.model,
      "size" => size,
      "quality" => config.params["quality"],
      "width" => width,
      "height" => height
    }

    Map.put(values, "config_hash", CanonicalJSON.hash(values))
  end

  defp parse_size!(size) when is_binary(size) do
    case String.split(size, "x", parts: 2) do
      [width, height] ->
        with {parsed_width, ""} <- Integer.parse(width),
             {parsed_height, ""} <- Integer.parse(height),
             true <- parsed_width > 0 and parsed_height > 0 do
          {parsed_width, parsed_height}
        else
          _ -> raise ArgumentError, "invalid image generation size: #{inspect(size)}"
        end

      _ ->
        raise ArgumentError, "invalid image generation size: #{inspect(size)}"
    end
  end

  defp template_snapshots do
    ~w(reference_image.json.eex shot_keyframe.json.eex)
    |> Map.new(fn name ->
      body = name |> template_path() |> File.read!()
      {name, CanonicalJSON.hash_bytes(body)}
    end)
  end

  defp template_path(name) do
    Application.app_dir(:dramatizer, "priv/generation_templates/#{@template_version}/#{name}")
  end

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when value in [true, false, nil], do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
