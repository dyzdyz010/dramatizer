defmodule Dramatizer.Directing.Compiler do
  @moduledoc "Pure deterministic ShotPlanRevision to GenerationSpecRevision compiler."

  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Projects
  alias Dramatizer.Projects.Project
  alias Dramatizer.Repo
  alias Dramatizer.Revisions
  alias Dramatizer.Revisions.{Draft, Revision}
  alias Dramatizer.Sources.SourceRevision

  @compiler_version "directing-compiler-v1"
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
          render_shot_spec(shot, profile, dependencies)
        end)

      payload = %{
        "schema_version" => "generation-spec-revision-v1",
        "frozen_inputs" => %{
          "source_revisions" => sources,
          "revisions" => revision_summaries,
          "production_profile" => profile,
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

  defp render_shot_spec(shot, profile, dependencies) do
    template_path("shot_keyframe.json.eex")
    |> EEx.eval_file(shot: shot, profile: profile, dependencies: dependencies)
    |> Jason.decode!()
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
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
