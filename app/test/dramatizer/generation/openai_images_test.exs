defmodule Dramatizer.Generation.OpenAIImagesTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Assets
  alias Dramatizer.Generation
  alias Dramatizer.Generation.Adapters.OpenAIImages
  alias Dramatizer.Projects

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  setup do
    previous_key = System.get_env("DRAMATIZER_TEST_OPENAI_IMAGE_KEY")
    previous_root = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "dramatizer-images-adapter-#{System.unique_integer([:positive])}"
      )

    System.put_env("DRAMATIZER_TEST_OPENAI_IMAGE_KEY", "image-test-secret")
    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      if previous_key,
        do: System.put_env("DRAMATIZER_TEST_OPENAI_IMAGE_KEY", previous_key),
        else: System.delete_env("DRAMATIZER_TEST_OPENAI_IMAGE_KEY")

      Application.put_env(:dramatizer, :asset_store_root, previous_root)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "generation posts gpt-image-2 JSON and decodes image, request ID, metadata, and usage" do
    test_pid = self()

    Req.Test.stub(__MODULE__.Generation, fn conn ->
      body = conn |> Req.Test.raw_body() |> Jason.decode!()
      send(test_pid, {:generation_request, conn.request_path, body})
      fixture = fixture_path("generation_success.json") |> File.read!() |> Jason.decode!()

      conn
      |> Plug.Conn.put_resp_header("x-request-id", "img_req_001")
      |> Req.Test.json(fixture)
    end)

    {snapshot, attempt, _project} = prepared_generation()

    assert {:ok, result} =
             OpenAIImages.submit(snapshot, attempt,
               plug: {Req.Test, __MODULE__.Generation},
               base_url: "http://openai.test"
             )

    assert [%{bytes: @png, mime_type: "image/png"}] = result.images
    assert result.request_id == "img_req_001"
    assert result.usage["total_tokens"] == 138

    assert_receive {:generation_request, "/v1/images/generations", body}

    assert body == %{
             "model" => "gpt-image-2",
             "prompt" => "中国竖屏短剧，雨夜车站",
             "size" => "1024x1536",
             "quality" => "medium",
             "output_format" => "png"
           }
  end

  test "edit sends multipart image array and optional mask without embedding bytes in snapshots" do
    test_pid = self()

    Req.Test.stub(__MODULE__.Edit, fn conn ->
      content_type = Plug.Conn.get_req_header(conn, "content-type") |> List.first()
      raw = Req.Test.raw_body(conn)
      send(test_pid, {:edit_request, conn.request_path, content_type, raw})
      fixture = fixture_path("generation_success.json") |> File.read!() |> Jason.decode!()
      Req.Test.json(conn, fixture)
    end)

    {snapshot, attempt, project} = prepared_generation()
    {:ok, parent} = store_asset(project, "parent")
    {:ok, mask} = store_asset(project, "mask")

    {:ok, edit_spec} =
      Generation.create_spec(project, %{
        kind: "image_edit",
        payload: %{"parent_asset_id" => parent.id, "mask_asset_id" => mask.id}
      })

    {:ok, edit_snapshot, edit_attempt} =
      Generation.prepare_attempt(edit_spec, :image_edit, project, %{
        task_override: %{
          credential_ref: "DRAMATIZER_TEST_OPENAI_IMAGE_KEY",
          model: "gpt-image-2"
        },
        request_input: %{
          "operation" => "edit",
          "prompt" => "保持角色一致，改成蓝色雨衣",
          "image_asset_ids" => [parent.id],
          "mask_asset_id" => mask.id,
          "output_format" => "png"
        }
      })

    refute inspect(edit_snapshot.request_input) =~ Base.encode64(@png)

    assert {:ok, _result} =
             OpenAIImages.submit(edit_snapshot, edit_attempt,
               plug: {Req.Test, __MODULE__.Edit},
               base_url: "http://openai.test"
             )

    assert_receive {:edit_request, "/v1/images/edits", "multipart/form-data; boundary=" <> _, raw}
    assert raw =~ ~s(name="model")
    assert raw =~ "gpt-image-2"
    assert raw =~ ~s(name="image[]"; filename="#{parent.id}.png")
    assert raw =~ ~s(name="mask"; filename="#{mask.id}.png")
    assert raw =~ "保持角色一致，改成蓝色雨衣"

    assert snapshot.adapter == "openai_images"
    assert attempt.status == :prepared
  end

  test "maps provider HTTP failures without returning credentials" do
    Req.Test.stub(__MODULE__.RateLimit, fn conn ->
      conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => %{"message" => "limited"}})
    end)

    {snapshot, attempt, _project} = prepared_generation()

    assert {:error, :rate_limited, %{status: 429} = metadata} =
             OpenAIImages.submit(snapshot, attempt,
               plug: {Req.Test, __MODULE__.RateLimit},
               base_url: "http://openai.test"
             )

    refute inspect(metadata) =~ "image-test-secret"
  end

  defp prepared_generation do
    {:ok, project} = Projects.create_project(%{name: "Images Adapter"})

    {:ok, spec} =
      Generation.create_spec(project, %{
        kind: "shot_keyframe",
        payload: %{"shot_id" => "S001"}
      })

    {:ok, snapshot, attempt} =
      Generation.prepare_attempt(spec, :shot_keyframe, project, %{
        task_override: %{
          credential_ref: "DRAMATIZER_TEST_OPENAI_IMAGE_KEY",
          model: "gpt-image-2"
        },
        request_input: %{
          "operation" => "generate",
          "prompt" => "中国竖屏短剧，雨夜车站",
          "size" => "1024x1536",
          "quality" => "medium",
          "output_format" => "png"
        }
      })

    {snapshot, attempt, project}
  end

  defp store_asset(project, key) do
    {:ok, intent} =
      Assets.create_upload_intent(project, %{
        purpose: "image",
        expected_mime: "image/png",
        idempotency_key: "images-adapter-#{key}-#{System.unique_integer([:positive])}"
      })

    {:ok, staged} = Assets.stage_bytes(intent, @png)
    Assets.finalize(staged, %{"origin" => "upload"})
  end

  defp fixture_path(name),
    do: Path.expand("../../support/fixtures/openai/images/#{name}", __DIR__)
end
