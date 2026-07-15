defmodule Dramatizer.Generation.OpenAIResponsesTest do
  use Dramatizer.DataCase, async: true

  alias Dramatizer.Analysis.Schemas
  alias Dramatizer.Generation
  alias Dramatizer.Generation.Adapters.OpenAIResponses
  alias Dramatizer.Projects

  setup do
    previous = System.get_env("DRAMATIZER_TEST_OPENAI_KEY")
    System.put_env("DRAMATIZER_TEST_OPENAI_KEY", "test-secret-never-persist")

    on_exit(fn ->
      if previous,
        do: System.put_env("DRAMATIZER_TEST_OPENAI_KEY", previous),
        else: System.delete_env("DRAMATIZER_TEST_OPENAI_KEY")
    end)

    :ok
  end

  test "posts stateless strict structured output and extracts output, request ID, and usage" do
    test_pid = self()

    Req.Test.stub(__MODULE__.Success, fn conn ->
      body = conn |> Req.Test.raw_body() |> Jason.decode!()

      send(
        test_pid,
        {:request, conn.method, conn.request_path, body,
         Plug.Conn.get_req_header(conn, "authorization")}
      )

      fixture = fixture_path("analysis_success.json") |> File.read!() |> Jason.decode!()

      conn
      |> Plug.Conn.put_resp_header("x-request-id", "req_header_001")
      |> Req.Test.json(fixture)
    end)

    {snapshot, attempt} = prepared_attempt()

    assert {:ok, result} =
             OpenAIResponses.submit(snapshot, attempt,
               plug: {Req.Test, __MODULE__.Success},
               base_url: "http://openai.test"
             )

    assert result.external_request_id == "resp_fixture_001"
    assert result.request_id == "req_header_001"
    assert result.usage["total_tokens"] == 160
    assert result.output["items"] |> hd() |> Map.fetch!("name") == "林夏"

    assert_receive {:request, "POST", "/v1/responses", body, ["Bearer test-secret-never-persist"]}
    assert body["store"] == false
    assert body["model"] == "fixture-model"
    assert body["text"]["format"]["type"] == "json_schema"
    assert body["text"]["format"]["strict"] == true
    assert body["text"]["format"]["schema"] == Schemas.fetch!(:people_relations)
    assert body["reasoning"] == %{"effort" => "medium"}
  end

  test "maps HTTP and transport failures to stable adapter errors" do
    Req.Test.stub(__MODULE__.RateLimit, fn conn ->
      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"message" => "slow down"}})
    end)

    Req.Test.stub(__MODULE__.Timeout, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    {snapshot, attempt} = prepared_attempt()

    assert {:error, :rate_limited, %{status: 429}} =
             OpenAIResponses.submit(snapshot, attempt,
               plug: {Req.Test, __MODULE__.RateLimit},
               base_url: "http://openai.test"
             )

    assert {:error, :provider_timeout, %{reason: :timeout}} =
             OpenAIResponses.submit(snapshot, attempt,
               plug: {Req.Test, __MODULE__.Timeout},
               base_url: "http://openai.test"
             )
  end

  defp prepared_attempt do
    {:ok, project} = Projects.create_project(%{name: "Responses Adapter"})

    {:ok, spec} =
      Generation.create_spec(project, %{
        kind: "people_relations",
        payload: %{"source_revision_ids" => ["11111111-1111-1111-1111-111111111111"]}
      })

    {:ok, snapshot, attempt} =
      Generation.prepare_attempt(spec, :people_relations, project, %{
        task_override: %{
          adapter: "openai_responses",
          credential_ref: "DRAMATIZER_TEST_OPENAI_KEY",
          model: "fixture-model",
          params: %{"reasoning" => %{"effort" => "medium"}}
        },
        request_input: %{
          "input" => "完整小说正文",
          "schema_name" => "people_relations",
          "schema" => Schemas.fetch!(:people_relations)
        }
      })

    {snapshot, attempt}
  end

  defp fixture_path(name),
    do: Path.expand("../../support/fixtures/openai/responses/#{name}", __DIR__)
end
