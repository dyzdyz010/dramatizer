defmodule Dramatizer.Generation.ConfigResolverTest do
  use Dramatizer.DataCase, async: true

  alias Dramatizer.Generation.ConfigResolver
  alias Dramatizer.Projects

  test "task override wins over project override and system default" do
    assert {:ok, project} = Projects.create_project(%{name: "配置测试"})

    system = ConfigResolver.resolve(:episode_candidates, project)
    assert system.adapter == "openai_responses"
    assert system.model == "gpt-5.6-terra"
    assert system.credential_ref == "OPENAI_API_KEY"

    assert {:ok, _override} =
             Projects.put_model_override(project, :episode_candidates, %{
               model: "gpt-5.6-sol",
               params: %{"reasoning" => %{"effort" => "high"}}
             })

    project_config = ConfigResolver.resolve(:episode_candidates, project)
    assert project_config.model == "gpt-5.6-sol"
    assert project_config.params["reasoning"]["effort"] == "high"

    task_config =
      ConfigResolver.resolve(:episode_candidates, project, %{
        model: "gpt-5.6-terra",
        params: %{"reasoning" => %{"effort" => "low"}, "temperature" => 0.2}
      })

    assert task_config.model == "gpt-5.6-terra"
    assert task_config.params["reasoning"]["effort"] == "low"
    assert task_config.params["temperature"] == 0.2
  end
end
