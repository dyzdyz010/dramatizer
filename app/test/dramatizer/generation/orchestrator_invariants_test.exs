defmodule Dramatizer.Generation.OrchestratorInvariantsTest do
  use Dramatizer.DataCase, async: false

  import Ecto.Query

  alias Dramatizer.Costs
  alias Dramatizer.Costs.CostEntry
  alias Dramatizer.Generation
  alias Dramatizer.Generation.Orchestrator
  alias Dramatizer.Projects
  alias Dramatizer.Repo

  setup do
    previous_root = Application.fetch_env!(:dramatizer, :asset_store_root)

    root =
      Path.join(
        System.tmp_dir!(),
        "dramatizer-orchestrator-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:dramatizer, :asset_store_root, root)

    on_exit(fn ->
      Application.put_env(:dramatizer, :asset_store_root, previous_root)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "real provider reserves the estimate before submission and records unknown actual cost" do
    assert {:ok, project} = Projects.create_project(%{name: "Provider 预算门"})
    assert {:ok, _budget} = Costs.set_budget(project, 100)

    assert {:ok, spec} =
             Generation.create_spec(project, %{
               kind: "shot_keyframe",
               payload: %{
                 "shot_id" => "S001",
                 "width" => 64,
                 "height" => 96,
                 "aspect_width" => 2,
                 "aspect_height" => 3,
                 "prompt" => "雨夜车站"
               }
             })

    png = fake_png()

    prompt_submitter = fn _snapshot, _attempt ->
      {:ok,
       %{
         output: %{"provider_prompt" => "AI 细化：雨夜车站，湿润地面反光，克制的电影灯光"},
         external_request_id: "prompt-budget-1",
         request_id: "req-prompt-budget-1",
         usage: %{"total_tokens" => 8}
       }}
    end

    submitter = fn snapshot, _attempt ->
      assert Costs.get_budget(project).reserved_micros == 70
      assert snapshot.request_input["prompt"] =~ "AI 细化"

      {:ok,
       %{
         images: [%{bytes: png, mime_type: "image/png"}],
         external_request_id: "image-budget-1",
         request_id: "req-budget-1",
         usage: %{"total_tokens" => 12},
         response_metadata: %{},
         cost_micros: nil
       }}
    end

    assert {:ok, _generated} =
             Orchestrator.generate(spec, :shot_keyframe, project,
               provider_mode: :openai,
               prompt_submitter: prompt_submitter,
               prompt_task_override: %{params: %{"estimated_cost_micros" => 0}},
               image_submitter: submitter,
               task_override: %{
                 params: %{
                   "estimated_cost_micros" => 70,
                   "size" => "64x96",
                   "quality" => "low"
                 }
               }
             )

    assert Costs.get_budget(project).reserved_micros == 0

    entries =
      Repo.all(
        from entry in CostEntry,
          where: entry.project_id == ^project.id,
          order_by: [asc: entry.inserted_at]
      )

    assert Enum.count(entries, &(&1.entry_type == :estimate)) == 2
    assert Enum.count(entries, &(&1.entry_type == :reservation)) == 2
    assert Enum.count(entries, &(&1.entry_type == :actual)) == 2
    assert Enum.any?(entries, &(&1.entry_type == :estimate and &1.amount_micros == 70))
    assert Enum.all?(Enum.filter(entries, &(&1.entry_type == :actual)), &is_nil(&1.amount_micros))
  end

  defp fake_png do
    assert {:ok, generated} =
             Dramatizer.Media.Worker.run(:generate_fake_image, %{
               "width" => 64,
               "height" => 96,
               "seed" => "budget-gate"
             })

    Base.decode64!(generated["png_base64"])
  end
end
