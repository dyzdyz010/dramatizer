defmodule Dramatizer.Quality do
  @moduledoc "Technical gates, semantic evidence, and explicit human selection decisions."

  import Ecto.Query

  alias Dramatizer.Assets.AssetVersion
  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Changes
  alias Dramatizer.Generation.GenerationSpec
  alias Dramatizer.Projects.Project
  alias Dramatizer.Quality.{QualityReport, SelectionDecision, SemanticQC, TechnicalQC}
  alias Dramatizer.Repo

  @semantic_dimensions ~w(identity_variant wardrobe location lighting key_props must_forbid composition camera action expression style artifacts)

  def run_technical(%AssetVersion{} = asset, %GenerationSpec{} = spec) do
    TechnicalQC.run(asset, spec)
  end

  def after_finalize(
        %AssetVersion{} = asset,
        %GenerationSpec{} = spec,
        %Project{} = project,
        opts \\ []
      ) do
    with {:ok, technical} <- TechnicalQC.run(asset, spec),
         {:ok, semantic} <- run_semantic_after_technical(technical, asset, spec, project, opts) do
      {:ok, %{technical: technical, semantic: semantic}}
    end
  end

  def run_semantic_fixture(%AssetVersion{} = asset, %GenerationSpec{} = spec, status \\ :pass)
      when status in [:pass, :fail, :warning, :inconclusive, :evaluator_failed] do
    dimension_status = if status == :pass, do: "pass", else: Atom.to_string(status)

    dimensions =
      Map.new(@semantic_dimensions, fn dimension ->
        {dimension,
         %{
           "status" => dimension_status,
           "confidence" => if(status == :pass, do: 0.99, else: 0.5),
           "reason" => "Fake evaluator evidence",
           "advice" => "User decides"
         }}
      end)

    input_hash =
      CanonicalJSON.hash(%{
        "asset_hash" => asset.blob_hash,
        "spec_hash" => spec.payload_hash,
        "fake_status" => Atom.to_string(status)
      })

    persist_report(%{
      project_id: asset.project_id,
      asset_version_id: asset.id,
      generation_spec_id: spec.id,
      kind: :semantic,
      status: status,
      blocking: false,
      evidence: %{"dimensions" => dimensions, "evaluator" => "fake-v1"},
      input_hash: input_hash
    })
  end

  def select(
        %Project{} = project,
        slot_key,
        %GenerationSpec{} = spec,
        %AssetVersion{} = asset,
        opts \\ []
      ) do
    case latest_report(asset.id, :technical) do
      %QualityReport{status: :pass, blocking: false} ->
        persist_selection(project, slot_key, spec, asset, opts)

      _ ->
        {:error, :technical_qc_failed}
    end
  end

  def latest_report(asset_id, kind) do
    Repo.one(
      from report in QualityReport,
        where: report.asset_version_id == ^asset_id and report.kind == ^kind,
        order_by: [desc: report.inserted_at, desc: report.id],
        limit: 1
    )
  end

  def persist_report(attrs) do
    changeset = QualityReport.create_changeset(%QualityReport{}, attrs)
    asset_id = Ecto.Changeset.get_field(changeset, :asset_version_id)
    kind = Ecto.Changeset.get_field(changeset, :kind)
    input_hash = Ecto.Changeset.get_field(changeset, :input_hash)

    Repo.insert(changeset,
      on_conflict: :nothing,
      conflict_target: [:asset_version_id, :kind, :input_hash]
    )

    {:ok,
     Repo.get_by!(QualityReport, asset_version_id: asset_id, kind: kind, input_hash: input_hash)}
  end

  defp persist_selection(project, slot_key, spec, asset, opts) do
    Repo.transaction(fn ->
      existing =
        Repo.one(
          from decision in SelectionDecision,
            where:
              decision.project_id == ^project.id and decision.slot_key == ^slot_key and
                decision.status == :active,
            lock: "FOR UPDATE"
        )

      if existing && existing.asset_version_id == asset.id do
        existing
      else
        changed_selection? = not is_nil(existing)

        if existing do
          existing
          |> SelectionDecision.supersede_changeset()
          |> Repo.update!()
        end

        semantic = latest_report(asset.id, :semantic)
        accepted_failure = not is_nil(semantic) and semantic.status != :pass

        decision =
          %SelectionDecision{}
          |> SelectionDecision.create_changeset(%{
            project_id: project.id,
            slot_key: slot_key,
            generation_spec_id: spec.id,
            asset_version_id: asset.id,
            accepted_semantic_failure: accepted_failure,
            note: Keyword.get(opts, :note),
            decided_at: DateTime.utc_now()
          })
          |> Repo.insert!()

        if changed_selection? and String.starts_with?(slot_key, "shot:") do
          ordered_slots =
            Repo.all(
              from selection in SelectionDecision,
                where:
                  selection.project_id == ^project.id and selection.status == :active and
                    like(selection.slot_key, "shot:%"),
                order_by: [asc: selection.slot_key],
                select: selection.slot_key
            )

          case Changes.schedule_neighbor_qc(project, ordered_slots, slot_key) do
            {:ok, _jobs} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        decision
      end
    end)
    |> case do
      {:ok, decision} -> {:ok, decision}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_semantic_after_technical(%QualityReport{status: :pass}, asset, spec, project, opts) do
    cond do
      Keyword.has_key?(opts, :evaluator) ->
        SemanticQC.run(asset, spec, project, opts)

      Application.fetch_env!(:dramatizer, :provider_mode) == :fake ->
        run_semantic_fixture(asset, spec, Keyword.get(opts, :fake_semantic_status, :pass))

      true ->
        SemanticQC.run(asset, spec, project, opts)
    end
  end

  defp run_semantic_after_technical(_technical, _asset, _spec, _project, _opts), do: {:ok, nil}
end
