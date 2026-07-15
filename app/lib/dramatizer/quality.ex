defmodule Dramatizer.Quality do
  @moduledoc "Technical gates, semantic evidence, and explicit human selection decisions."

  import Ecto.Query

  alias Dramatizer.Assets
  alias Dramatizer.Assets.AssetVersion
  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Generation.GenerationSpec
  alias Dramatizer.Projects.Project
  alias Dramatizer.Quality.{QualityReport, SelectionDecision}
  alias Dramatizer.Repo

  @semantic_dimensions ~w(identity_variant wardrobe location lighting key_props must_forbid composition camera action expression style artifacts)

  def run_technical(%AssetVersion{} = asset, %GenerationSpec{} = spec) do
    verification = Assets.verify(asset)
    width = asset.width
    height = asset.height
    expected_width = spec.payload["width"]
    expected_height = spec.payload["height"]

    checks = %{
      "blob_integrity" => check(verification == :ok, verification),
      "decodable" => check(is_integer(width) and is_integer(height), :missing_dimensions),
      "dimensions_positive" =>
        check(
          is_integer(width) and width > 0 and is_integer(height) and height > 0,
          :invalid_dimensions
        ),
      "aspect" =>
        check(aspect_matches?(width, height, expected_width, expected_height), :aspect_mismatch),
      "mime_type" => check(String.starts_with?(asset.mime_type, "image/"), :invalid_image_mime)
    }

    failed = Enum.any?(checks, fn {_name, evidence} -> evidence["status"] == "fail" end)
    status = if failed, do: :fail, else: :pass

    input_hash =
      CanonicalJSON.hash(%{
        "asset_hash" => asset.blob_hash,
        "spec_hash" => spec.payload_hash,
        "observed_verification" => inspect(verification),
        "checks" => checks
      })

    insert_report(%{
      project_id: asset.project_id,
      asset_version_id: asset.id,
      generation_spec_id: spec.id,
      kind: :technical,
      status: status,
      blocking: failed,
      evidence: %{"checks" => checks},
      input_hash: input_hash
    })
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

    insert_report(%{
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
        if existing do
          existing
          |> SelectionDecision.supersede_changeset()
          |> Repo.update!()
        end

        semantic = latest_report(asset.id, :semantic)
        accepted_failure = not is_nil(semantic) and semantic.status != :pass

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
      end
    end)
    |> case do
      {:ok, decision} -> {:ok, decision}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_report(attrs) do
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

  defp aspect_matches?(_width, _height, nil, nil), do: true

  defp aspect_matches?(width, height, expected_width, expected_height)
       when is_integer(width) and is_integer(height) and is_integer(expected_width) and
              is_integer(expected_height) do
    width * expected_height == height * expected_width
  end

  defp aspect_matches?(_width, _height, _expected_width, _expected_height), do: false

  defp check(true, _reason), do: %{"status" => "pass"}
  defp check(false, reason), do: %{"status" => "fail", "reason" => inspect(reason)}
end
