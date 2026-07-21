defmodule Dramatizer.Generation.StructuredTextProposalTest do
  use Dramatizer.DataCase, async: false

  alias Dramatizer.Generation.{Attempt, StructuredTextProposal}
  alias Dramatizer.Projects
  alias Dramatizer.Repo

  setup do
    assert {:ok, project} = Projects.create_project(%{name: "结构化生产提案"})
    %{project: project}
  end

  test "fake production proposals persist rich outputs through the request and attempt contract",
       %{
         project: project
       } do
    assert Code.ensure_loaded?(StructuredTextProposal)

    for {task, version, required_key} <- [
          {:narrative_proposal, "narrative-draft-v2", "scenes"},
          {:visual_design_proposal, "visual-design-draft-v2", "objects"},
          {:directing_proposal, "shot-plan-draft-v2", "shots"}
        ] do
      assert {:ok, result} =
               apply(StructuredTextProposal, :propose, [
                 project,
                 task,
                 authority(),
                 [provider_mode: :fake]
               ])

      assert result.output["schema_version"] == version
      assert is_list(result.output[required_key])
      assert result.request_snapshot.task_type == Atom.to_string(task)
      assert result.request_snapshot.secrets_excluded
      assert result.attempt.status == :succeeded
    end
  end

  test "identical authority reuses the succeeded proposal attempt", %{project: project} do
    assert Code.ensure_loaded?(StructuredTextProposal)

    args = [project, :narrative_proposal, authority(), [provider_mode: :fake]]
    assert {:ok, first} = apply(StructuredTextProposal, :propose, args)
    assert {:ok, second} = apply(StructuredTextProposal, :propose, args)

    assert second.request_snapshot.id == first.request_snapshot.id
    assert second.attempt.id == first.attempt.id
    assert Repo.aggregate(Attempt, :count) == 1
  end

  test "invalid structured output fails the attempt instead of guessing fields", %{
    project: project
  } do
    assert Code.ensure_loaded?(StructuredTextProposal)

    submitter = fn _snapshot, _attempt ->
      {:ok,
       %{
         output: %{"bad" => true},
         external_request_id: "response_bad",
         request_id: "req_bad",
         usage: %{}
       }}
    end

    assert {:error, :invalid_proposal_output} =
             apply(StructuredTextProposal, :propose, [
               project,
               :visual_design_proposal,
               authority(),
               [provider_mode: :openai, submitter: submitter]
             ])

    assert Repo.one!(Attempt).status == :failed
    assert Repo.one!(Attempt).error_code == "invalid_proposal_output"
  end

  test "submission timeout is held as unknown remote state without an automatic retry", %{
    project: project
  } do
    owner = self()

    submitter = fn _snapshot, _attempt ->
      send(owner, :submitted)
      {:error, :provider_timeout, %{reason: :socket_timeout}}
    end

    options = [provider_mode: :openai, submitter: submitter]

    assert {:error, :unknown_remote_state} =
             StructuredTextProposal.propose(
               project,
               :narrative_proposal,
               authority(),
               options
             )

    assert_receive :submitted

    assert {:error, :unknown_remote_state} =
             StructuredTextProposal.propose(
               project,
               :narrative_proposal,
               authority(),
               options
             )

    refute_receive :submitted
    assert Repo.one!(Attempt).status == :unknown_remote_state
  end

  defp authority do
    %{
      "episode" => %{"id" => "episode:001", "title" => "雨夜来信"},
      "people" => [%{"id" => "person:lin", "name" => "林夏"}],
      "locations" => [%{"id" => "location:station", "name" => "雨夜车站"}],
      "events" => [%{"id" => "event:letter", "name" => "收到匿名信"}]
    }
  end
end
