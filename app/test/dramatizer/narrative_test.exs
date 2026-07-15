defmodule Dramatizer.NarrativeTest do
  use Dramatizer.DataCase, async: true

  alias Dramatizer.Analysis.AnalysisSnapshot
  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Narrative
  alias Dramatizer.Projects
  alias Dramatizer.Repo
  alias Dramatizer.Revisions
  alias Dramatizer.Revisions.Revision
  alias Dramatizer.Workflow

  test "selecting one episode materializes only its dependency closure as an editable draft" do
    assert {:ok, project} = Projects.create_project(%{name: "分集物化"})
    assert {:ok, run} = Workflow.create_run(project, "fixture", %{}, "fixture-analysis")

    node_results = %{
      "people_relations" => %{
        "output" => %{"items" => [item("person:p1"), item("person:unused")]}
      },
      "events_timeline" => %{
        "output" => %{"items" => [item("event:e1", ["person:p1"]), item("event:unused")]}
      },
      "places_props_world" => %{
        "output" => %{"items" => [item("place:l1"), item("place:unused")]}
      },
      "entity_merge" => %{"output" => %{"items" => []}},
      "episode_candidates" => %{
        "output" => %{
          "items" => [
            item("episode:ep1", ["event:e1", "place:l1"]),
            item("episode:ep2", ["event:unused"])
          ]
        }
      },
      "conflict_check" => %{"output" => %{"items" => []}}
    }

    snapshot =
      %AnalysisSnapshot{}
      |> AnalysisSnapshot.create_changeset(%{
        project_id: project.id,
        workflow_run_id: run.id,
        source_revision_ids: [],
        task_snapshot_ids: [],
        node_results: node_results,
        content_hash: CanonicalJSON.hash(node_results)
      })
      |> Repo.insert!()

    assert {:ok, draft} = Narrative.materialize_episode(project, snapshot, "episode:ep1")
    assert draft.kind == :narrative
    assert draft.status == :editing
    assert draft.payload["episode"]["id"] == "episode:ep1"

    assert draft.payload["dependencies"] |> Enum.map(& &1["id"]) |> Enum.sort() ==
             ~w(event:e1 person:p1 place:l1)

    refute draft.payload |> Jason.encode!() |> String.contains?("unused")
    assert Repo.aggregate(Revision, :count) == 0

    assert {:ok, edited} = Revisions.update_draft(draft, %{"title" => "人工修订标题"})
    assert {:ok, revision} = Revisions.confirm_draft(edited.id)
    assert revision.kind == :narrative
    assert revision.payload["title"] == "人工修订标题"
  end

  defp item(id, references \\ []) do
    %{
      "id" => id,
      "kind" => id |> String.split(":") |> hd(),
      "name" => id,
      "source_semantics" => "source_grounded",
      "locators" => [],
      "references" => references,
      "data" => %{}
    }
  end
end
