defmodule Dramatizer.Quality.TechnicalQCTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Assets
  alias Dramatizer.Generation
  alias Dramatizer.Projects
  alias Dramatizer.Quality
  alias Dramatizer.Quality.TechnicalQC

  setup do
    previous = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "dramatizer-technical-qc-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous)
      File.rm_rf!(root)
    end)

    assert {:ok, project} = Projects.create_project(%{name: "技术 QC"})
    %{project: project}
  end

  test "checks live decode, integrity, format, exact dimensions, aspect tolerance, and minimums",
       context do
    assert {:ok, asset} = store_image(context.project, 540, 960, "image/png", "valid")

    assert {:ok, spec} =
             Generation.create_spec(context.project, %{
               kind: "shot_keyframe",
               payload: %{
                 "width" => 540,
                 "height" => 960,
                 "minimum_width" => 500,
                 "minimum_height" => 900,
                 "aspect_width" => 9,
                 "aspect_height" => 16,
                 "aspect_tolerance" => 0.01,
                 "allowed_formats" => ["png"]
               }
             })

    assert {:ok, report} = TechnicalQC.run(asset, spec)
    assert report.status == :pass
    refute report.blocking

    checks = report.evidence["checks"]

    for key <- ~w(blob_integrity decodable format exact_dimensions aspect minimum_dimensions) do
      assert checks[key]["status"] == "pass"
    end
  end

  test "hard failures block selection and report independent reasons", context do
    assert {:ok, asset} = store_image(context.project, 600, 800, "image/jpeg", "bad-spec")

    assert {:ok, spec} =
             Generation.create_spec(context.project, %{
               kind: "shot_keyframe",
               payload: %{
                 "width" => 540,
                 "height" => 960,
                 "minimum_width" => 720,
                 "minimum_height" => 1280,
                 "aspect_width" => 9,
                 "aspect_height" => 16,
                 "aspect_tolerance" => 0.001,
                 "allowed_formats" => ["png"]
               }
             })

    assert {:ok, report} = TechnicalQC.run(asset, spec)
    assert report.status == :fail
    assert report.blocking
    assert report.evidence["checks"]["format"]["status"] == "fail"
    assert report.evidence["checks"]["exact_dimensions"]["status"] == "fail"
    assert report.evidence["checks"]["aspect"]["status"] == "fail"
    assert report.evidence["checks"]["minimum_dimensions"]["status"] == "fail"
    assert {:error, :technical_qc_failed} = Quality.select(context.project, "bad", spec, asset)

    File.write!(Assets.absolute_path(asset), "not-an-image")
    assert {:ok, corrupted} = TechnicalQC.run(asset, spec)
    assert corrupted.evidence["checks"]["blob_integrity"]["status"] == "fail"
    assert corrupted.evidence["checks"]["decodable"]["status"] == "fail"
  end

  defp store_image(project, width, height, expected_mime, key) do
    {:ok, generated} =
      Dramatizer.Media.Worker.run(:generate_fake_image, %{
        "width" => width,
        "height" => height,
        "seed" => key
      })

    bytes = Base.decode64!(generated["png_base64"])

    {:ok, intent} =
      Assets.create_upload_intent(project, %{
        purpose: "qc",
        expected_mime: expected_mime,
        idempotency_key: "technical-qc-#{key}"
      })

    {:ok, staged} = Assets.stage_bytes(intent, bytes)
    Assets.finalize(staged, %{"origin" => "fixture"})
  end
end
