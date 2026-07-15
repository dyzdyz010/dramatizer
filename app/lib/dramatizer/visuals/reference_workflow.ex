defmodule Dramatizer.Visuals.ReferenceWorkflow do
  @moduledoc "Reference/shot candidate preparation, upload/edit lineage, and formal promotion."

  alias Dramatizer.Assets
  alias Dramatizer.Assets.AssetVersion
  alias Dramatizer.Generation
  alias Dramatizer.Generation.{Attempt, ConfigResolver, GenerationSpec}
  alias Dramatizer.Projects.Project
  alias Dramatizer.Quality

  def prepare_candidates(project, kind, compilation, opts \\ [])

  def prepare_candidates(%Project{} = project, kind, compilation, opts)
      when kind in [:reference, :shot] do
    task_type = if kind == :reference, do: :reference_image, else: :shot_keyframe
    task_override = Keyword.get(opts, :task_override, %{})
    config = ConfigResolver.resolve(task_type, project, task_override)
    candidate_count = config.params["candidate_count"]
    formal = Keyword.get(opts, :formal, true)

    if is_integer(candidate_count) and candidate_count > 0 do
      prepared =
        Enum.map(0..(candidate_count - 1), fn candidate_index ->
          payload = %{
            "provider_prompt" => compilation.provider_prompt,
            "provider_prompt_hash" => compilation.provider_prompt_hash,
            "chinese_authority_hash" => compilation.chinese_authority_hash,
            "links" => compilation.links,
            "candidate_count" => candidate_count,
            "formal" => formal
          }

          {:ok, spec} =
            Generation.create_spec(project, %{
              kind: Atom.to_string(task_type),
              candidate_index: candidate_index,
              formal: formal,
              payload: payload
            })

          {:ok, snapshot, attempt} =
            Generation.prepare_attempt(spec, task_type, project, %{
              task_override: task_override,
              request_input: %{
                "operation" => "generate",
                "prompt" => compilation.provider_prompt,
                "size" => config.params["size"],
                "quality" => config.params["quality"],
                "output_format" => "png",
                "candidate_count" => candidate_count,
                "candidate_index" => candidate_index,
                "formal" => formal
              },
              prompt_snapshot: prompt_snapshot(compilation)
            })

          %{spec: spec, snapshot: snapshot, attempt: attempt, compilation: compilation}
        end)

      {:ok, prepared}
    else
      {:error, :invalid_candidate_count}
    end
  end

  def upload(%Project{} = project, path, opts \\ []) do
    purpose = Keyword.get(opts, :purpose, "reference_upload")

    Assets.import_file(project, path, %{
      purpose: purpose,
      expected_mime: mime_from_path(path),
      idempotency_key: "upload:#{purpose}:#{file_hash(path)}"
    })
  end

  def prepare_edit(
        %Project{id: project_id} = project,
        %AssetVersion{project_id: project_id} = parent,
        compilation,
        opts \\ []
      ) do
    mask = Keyword.get(opts, :mask_asset)
    formal = Keyword.get(opts, :formal, false)
    task_override = Keyword.get(opts, :task_override, %{})
    config = ConfigResolver.resolve(:image_edit, project, task_override)

    payload = %{
      "parent_asset_id" => parent.id,
      "parent_blob_hash" => parent.blob_hash,
      "mask_asset_id" => mask && mask.id,
      "mask_blob_hash" => mask && mask.blob_hash,
      "provider_prompt" => compilation.provider_prompt,
      "provider_prompt_hash" => compilation.provider_prompt_hash,
      "formal" => formal
    }

    with {:ok, spec} <-
           Generation.create_spec(project, %{
             kind: "image_edit",
             formal: formal,
             payload: payload
           }),
         {:ok, snapshot, attempt} <-
           Generation.prepare_attempt(spec, :image_edit, project, %{
             task_override: task_override,
             request_input: %{
               "operation" => "edit",
               "prompt" => compilation.provider_prompt,
               "image_asset_ids" => [parent.id],
               "mask_asset_id" => mask && mask.id,
               "size" => config.params["size"],
               "quality" => config.params["quality"],
               "output_format" => "png",
               "formal" => formal
             },
             prompt_snapshot: prompt_snapshot(compilation)
           }) do
      {:ok, %{spec: spec, snapshot: snapshot, attempt: attempt, compilation: compilation}}
    end
  end

  def finalize_result(%Project{} = project, prepared, %{bytes: bytes, mime_type: mime_type}) do
    with {:ok, submitted} <- ensure_submitted(prepared.attempt),
         {:ok, intent} <-
           Assets.create_upload_intent(project, %{
             purpose: prepared.spec.kind,
             expected_mime: mime_type,
             idempotency_key: "attempt:#{submitted.id}:image"
           }),
         {:ok, staged} <- Assets.stage_bytes(intent, bytes),
         {:ok, asset} <-
           Assets.finalize(staged, %{
             "origin" => prepared.snapshot.adapter,
             "generation_spec_id" => prepared.spec.id,
             "provider_request_snapshot_id" => prepared.snapshot.id,
             "attempt_id" => submitted.id,
             "parent_asset_id" => prepared.spec.payload["parent_asset_id"],
             "mask_asset_id" => prepared.spec.payload["mask_asset_id"],
             "formal" => prepared.spec.formal
           }),
         {:ok, _qc} <- Quality.after_finalize(asset, prepared.spec, project),
         {:ok, _succeeded} <-
           Generation.transition_attempt(submitted, :succeeded, %{
             result_asset_id: asset.id,
             response_metadata: %{"mime_type" => mime_type}
           }) do
      {:ok, asset}
    end
  end

  def promote(%Project{} = project, %{spec: %GenerationSpec{formal: false} = old_spec} = prepared) do
    task_type = String.to_existing_atom(prepared.snapshot.task_type)

    payload =
      old_spec.payload
      |> Map.put("formal", true)
      |> Map.put("promoted_from_spec_id", old_spec.id)

    override = %{
      adapter: prepared.snapshot.adapter,
      credential_ref: prepared.snapshot.credential_ref,
      model: prepared.snapshot.model,
      params: prepared.snapshot.params
    }

    with {:ok, spec} <-
           Generation.create_spec(project, %{
             kind: old_spec.kind,
             candidate_index: old_spec.candidate_index,
             formal: true,
             payload: payload
           }),
         {:ok, snapshot, attempt} <-
           Generation.prepare_attempt(spec, task_type, project, %{
             task_override: override,
             request_input:
               prepared.snapshot.request_input
               |> Map.put("formal", true)
               |> Map.put("promoted_from_spec_id", old_spec.id),
             prompt_snapshot: prepared.snapshot.prompt_snapshot
           }) do
      {:ok, %{prepared | spec: spec, snapshot: snapshot, attempt: attempt}}
    end
  end

  def promote(%Project{}, _prepared), do: {:error, :already_formal}

  def formal_timeline_eligible?(%AssetVersion{lineage: lineage}), do: lineage["formal"] == true

  defp ensure_submitted(%Attempt{status: :prepared} = attempt),
    do: Generation.transition_attempt(attempt, :submitted)

  defp ensure_submitted(%Attempt{status: :submitted} = attempt), do: {:ok, attempt}
  defp ensure_submitted(%Attempt{}), do: {:error, :attempt_not_finalizable}

  defp prompt_snapshot(compilation) do
    %{
      "compiler_version" => compilation.compiler_version,
      "chinese_authority" => compilation.chinese_authority,
      "chinese_authority_hash" => compilation.chinese_authority_hash,
      "provider_prompt_hash" => compilation.provider_prompt_hash,
      "links" => compilation.links
    }
  end

  defp mime_from_path(path) do
    case path |> Path.extname() |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      _ -> "image/png"
    end
  end

  defp file_hash(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
