defmodule Dramatizer.Generation.Pipeline do
  @moduledoc "Persisted DAG definitions and node execution for generation work."

  import Ecto.Query

  alias Dramatizer.Assets
  alias Dramatizer.Analysis.AnalysisSnapshot
  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Directing
  alias Dramatizer.Generation.{GenerationSpec, ImagePromptProposal, Orchestrator}
  alias Dramatizer.Generation.Jobs.GenerationNodeJob
  alias Dramatizer.Generation.StructuredTextProposal
  alias Dramatizer.Execution.Notifier
  alias Dramatizer.Narrative
  alias Dramatizer.Projects.Project
  alias Dramatizer.Quality
  alias Dramatizer.Quality.{SelectionDecision, SemanticQC}
  alias Dramatizer.Repo
  alias Dramatizer.Revisions.Revision
  alias Dramatizer.Visuals
  alias Dramatizer.Workflow
  alias Dramatizer.Workflow.{NodeRun, WorkflowRun}
  alias Dramatizer.Workflow.Enqueue

  @image_tasks ~w(reference_image shot_keyframe image_edit)a
  @proposal_tasks ~w(narrative_proposal visual_design_proposal directing_proposal)a

  @image_definition [
    {"prompt_proposal", []},
    {"asset_generation", ["prompt_proposal"]},
    {"technical_qc", ["asset_generation"]},
    {"semantic_qc", ["asset_generation"]}
  ]

  def enqueue(project, spec, task_type, opts \\ [])

  def enqueue(
        %Project{id: project_id} = project,
        %GenerationSpec{project_id: project_id} = spec,
        task_type,
        opts
      )
      when task_type in @image_tasks do
    input = %{
      "generation_spec_id" => spec.id,
      "task_type" => Atom.to_string(task_type),
      "options" => durable_options(opts)
    }

    Repo.transaction(fn ->
      with {:ok, run} <-
             Workflow.create_run(
               project,
               "image_generation_v1",
               input,
               "image-generation:#{spec.id}:#{task_type}:#{CanonicalJSON.hash(input)}"
             ),
           {:ok, nodes} <- add_nodes(run, @image_definition, input),
           {:ok, running} <- ensure_running(run),
           {:ok, executions} <-
             enqueue_nodes(nodes, &(&1.node_key == "prompt_proposal"), opts) do
        %{run: running, executions: executions}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> finish_enqueue()
  end

  def enqueue(%Project{}, %GenerationSpec{}, task_type, _opts),
    do: {:error, {:unsupported_generation_task, task_type}}

  def enqueue_proposal(project, task_type, authority, opts \\ [])

  def enqueue_proposal(%Project{} = project, task_type, authority, opts)
      when task_type in @proposal_tasks and is_map(authority) do
    input = %{
      "task_type" => Atom.to_string(task_type),
      "authority" => authority,
      "options" => durable_options(opts)
    }

    Repo.transaction(fn ->
      with {:ok, run} <-
             Workflow.create_run(
               project,
               "structured_proposal_v1",
               input,
               "structured-proposal:#{task_type}:#{CanonicalJSON.hash(input)}"
             ),
           {:ok, node} <- Workflow.add_node(run, "structured_proposal", input, []),
           {:ok, running} <- ensure_running(run),
           {:ok, executions} <- enqueue_nodes([node], fn _node -> true end, opts) do
        %{run: running, executions: executions}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> finish_enqueue()
  end

  def enqueue_proposal(%Project{}, task_type, _authority, _opts),
    do: {:error, {:unsupported_proposal_task, task_type}}

  def execute_node(%NodeRun{node_key: "structured_proposal"} = node, %Project{} = project) do
    task_type = String.to_existing_atom(node.input_snapshot["task_type"])
    authority = node.input_snapshot["authority"]

    case StructuredTextProposal.propose(project, task_type, authority, node_run_id: node.id) do
      {:ok, proposal} ->
        with {:ok, draft_id} <- materialize_proposal(node, project, task_type, proposal.output) do
          {:ok,
           %{
             "output" => proposal.output,
             "provider_request_snapshot_id" => proposal.request_snapshot.id,
             "attempt_id" => proposal.attempt.id,
             "draft_id" => draft_id
           }}
        else
          {:error, reason} -> {:error, reason, %{}}
        end

      {:error, reason} ->
        {:error, reason, %{}}
    end
  end

  def execute_node(%NodeRun{node_key: "prompt_proposal"} = node, %Project{} = project) do
    spec = generation_spec!(node)
    task_type = generation_task!(node)

    case ImagePromptProposal.propose(project, task_type, spec.payload, node_run_id: node.id) do
      {:ok, proposal} ->
        {:ok,
         %{
           "provider_prompt" => proposal.provider_prompt,
           "provider_prompt_hash" => proposal.provider_prompt_hash,
           "provider_request_snapshot_id" => proposal.request_snapshot.id,
           "attempt_id" => proposal.attempt.id
         }}

      {:error, reason} ->
        {:error, reason, %{}}
    end
  end

  def execute_node(%NodeRun{node_key: "asset_generation"} = node, %Project{} = project) do
    spec = generation_spec!(node)
    task_type = generation_task!(node)
    prompt = parent_result!(node, "prompt_proposal")

    options =
      node
      |> generation_options(prompt)
      |> Keyword.put(:defer_quality, true)
      |> Keyword.put(:node_run_id, node.id)

    case Orchestrator.generate(spec, task_type, project, options) do
      {:ok, generated} ->
        {:ok,
         %{
           "asset_version_id" => generated.asset.id,
           "generation_spec_id" => spec.id,
           "provider_request_snapshot_id" => generated.request_snapshot.id,
           "attempt_id" => generated.attempt.id
         }}

      {:error, reason} ->
        {:error, reason, %{}}
    end
  end

  def execute_node(%NodeRun{node_key: "technical_qc"} = node, %Project{}) do
    {asset, spec} = quality_inputs!(node)

    case Quality.run_technical(asset, spec) do
      {:ok, report} ->
        {:ok,
         %{
           "quality_report_id" => report.id,
           "asset_version_id" => asset.id,
           "status" => Atom.to_string(report.status)
         }}

      {:error, reason} ->
        {:error, reason, %{}}
    end
  end

  def execute_node(%NodeRun{node_key: "semantic_qc"} = node, %Project{} = project) do
    {asset, spec} = quality_inputs!(node)
    options = node.input_snapshot["options"] || %{}

    result =
      if Application.fetch_env!(:dramatizer, :provider_mode) == :fake do
        Quality.run_semantic_fixture(asset, spec)
      else
        SemanticQC.run(asset, spec, project,
          node_run_id: node.id,
          selected_neighbors: selected_neighbors(options["selected_neighbor_ids"] || %{}),
          evaluation_key: options["evaluation_key"] || "default"
        )
      end

    case result do
      {:ok, report} ->
        {:ok,
         %{
           "quality_report_id" => report.id,
           "asset_version_id" => asset.id,
           "status" => Atom.to_string(report.status)
         }}

      {:error, reason} ->
        {:error, reason, %{}}
    end
  end

  def execute_node(%NodeRun{node_key: node_key}, %Project{}),
    do: {:error, {:unsupported_generation_node, node_key}, %{}}

  def advance(%NodeRun{} = node, %Project{} = project, opts \\ []) do
    notify? = Keyword.get(opts, :notify, true)

    with :ok <- enqueue_ready_nodes(node.workflow_run_id, notify?) do
      nodes = Repo.all(from item in NodeRun, where: item.workflow_run_id == ^node.workflow_run_id)

      cond do
        nodes != [] and Enum.all?(nodes, &(&1.status == :succeeded)) ->
          run = Repo.get!(WorkflowRun, node.workflow_run_id)

          with {:ok, _run} <- Workflow.mark_run(run, :succeeded) do
            if notify?,
              do: Notifier.broadcast(project.id, :generation, run.id, :succeeded),
              else: :ok
          end

        Enum.any?(nodes, &(&1.status == :failed)) ->
          mark_failed(node.workflow_run_id, project, node.id, notify: notify?)

        true ->
          :ok
      end
    end
  end

  def mark_failed(run_id, project, resource_id, opts \\ []) do
    run = Repo.get!(WorkflowRun, run_id)

    with {:ok, _run} <- Workflow.mark_run(run, :failed) do
      if Keyword.get(opts, :notify, true),
        do: Notifier.broadcast(project.id, :generation, resource_id, :failed),
        else: :ok
    end
  end

  defp add_nodes(run, definition, input) do
    nodes =
      Enum.map(definition, fn {node_key, parents} ->
        {:ok, node} = Workflow.add_node(run, node_key, input, parents)
        node
      end)

    {:ok, nodes}
  end

  defp ensure_running(%WorkflowRun{status: :succeeded} = run), do: {:ok, run}
  defp ensure_running(%WorkflowRun{} = run), do: Workflow.mark_run(run, :running)

  defp enqueue_nodes(nodes, predicate, opts) do
    nodes
    |> Enum.filter(&(&1.status == :queued and predicate.(&1)))
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, executions} ->
      case Enqueue.node(node, GenerationNodeJob,
             job_options: Keyword.get(opts, :job_options, []),
             notify: false
           ) do
        {:ok, execution} -> {:cont, {:ok, [execution | executions]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, executions} -> {:ok, Enum.reverse(executions)}
      error -> error
    end)
  end

  defp enqueue_ready_nodes(run_id, notify?) do
    case Enqueue.ready_nodes(run_id, &worker_for/1, notify: notify?) do
      {:ok, _executions} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp worker_for(%NodeRun{node_key: "technical_qc"}),
    do: Dramatizer.Quality.Jobs.TechnicalQCJob

  defp worker_for(%NodeRun{node_key: "semantic_qc"}),
    do: Dramatizer.Quality.Jobs.SemanticQCJob

  defp worker_for(%NodeRun{}), do: GenerationNodeJob

  defp finish_enqueue({:ok, %{run: run, executions: executions}}) do
    Enum.each(executions, &Enqueue.notify(&1.node))
    {:ok, run}
  end

  defp finish_enqueue({:error, reason}), do: {:error, reason}

  defp generation_spec!(node) do
    node.input_snapshot
    |> Map.fetch!("generation_spec_id")
    |> then(&Repo.get!(GenerationSpec, &1))
  end

  defp generation_task!(node) do
    task_type = node.input_snapshot["task_type"]
    Enum.find(@image_tasks, &(Atom.to_string(&1) == task_type)) || raise "invalid image task"
  end

  defp parent_result!(node, parent_key) do
    Repo.one!(
      from parent in NodeRun,
        where: parent.workflow_run_id == ^node.workflow_run_id and parent.node_key == ^parent_key,
        select: parent.result
    )
  end

  defp quality_inputs!(node) do
    result = parent_result!(node, "asset_generation")

    {
      Assets.get_asset!(Map.fetch!(result, "asset_version_id")),
      Repo.get!(GenerationSpec, Map.fetch!(result, "generation_spec_id"))
    }
  end

  defp selected_neighbors(ids) do
    Enum.flat_map(ids, fn {position, id} ->
      case Repo.get(SelectionDecision, id) do
        %SelectionDecision{} = selection -> [{String.to_existing_atom(position), selection}]
        nil -> []
      end
    end)
  end

  defp materialize_proposal(node, project, task_type, output) do
    case get_in(node.input_snapshot, ["options", "materialization"]) do
      nil ->
        {:ok, nil}

      %{
        "kind" => "narrative",
        "analysis_snapshot_id" => snapshot_id,
        "candidate_id" => candidate_id
      }
      when task_type == :narrative_proposal ->
        with {:ok, draft} <-
               Narrative.create_proposal_draft(
                 project,
                 Repo.get!(AnalysisSnapshot, snapshot_id),
                 candidate_id,
                 output
               ) do
          {:ok, draft.id}
        end

      %{"kind" => "visual_design", "narrative_revision_id" => narrative_id}
      when task_type == :visual_design_proposal ->
        with {:ok, draft} <-
               Visuals.create_proposal_draft(project, Repo.get!(Revision, narrative_id), output) do
          {:ok, draft.id}
        end

      %{
        "kind" => "directing",
        "narrative_revision_id" => narrative_id,
        "visual_design_revision_id" => visual_id,
        "reference_set_revision_id" => reference_id
      }
      when task_type == :directing_proposal ->
        with {:ok, draft} <-
               Directing.create_proposal_draft(
                 project,
                 Repo.get!(Revision, narrative_id),
                 Repo.get!(Revision, visual_id),
                 Repo.get!(Revision, reference_id),
                 output
               ) do
          {:ok, draft.id}
        end

      _invalid ->
        {:error, :invalid_proposal_materialization}
    end
  end

  defp generation_options(node, prompt) do
    options = node.input_snapshot["options"] || %{}

    [
      prompt_proposal: %{
        provider_prompt: Map.fetch!(prompt, "provider_prompt"),
        provider_prompt_hash: Map.fetch!(prompt, "provider_prompt_hash"),
        request_snapshot_id: Map.fetch!(prompt, "provider_request_snapshot_id"),
        attempt_id: Map.fetch!(prompt, "attempt_id")
      },
      prompt_snapshot: %{
        "proposal_request_snapshot_id" => Map.fetch!(prompt, "provider_request_snapshot_id"),
        "proposal_attempt_id" => Map.fetch!(prompt, "attempt_id"),
        "proposal_prompt_hash" => Map.fetch!(prompt, "provider_prompt_hash")
      }
    ]
    |> maybe_put_option(:task_override, options["task_override"])
    |> maybe_put_option(:fault_profile, options["fault_profile"])
    |> maybe_put_option(:reference_assets, load_assets(options["reference_asset_ids"]))
  end

  defp load_assets(nil), do: nil
  defp load_assets(ids) when is_list(ids), do: Enum.map(ids, &Assets.get_asset!/1)

  defp maybe_put_option(options, _key, nil), do: options
  defp maybe_put_option(options, key, value), do: Keyword.put(options, key, value)

  defp durable_options(opts) do
    opts
    |> Keyword.take([
      :reference_asset_ids,
      :selected_neighbor_ids,
      :evaluation_key,
      :task_override,
      :fault_profile,
      :materialization
    ])
    |> Map.new()
    |> stringify()
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when value in [true, false, nil], do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
