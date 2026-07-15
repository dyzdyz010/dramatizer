defmodule DramatizerWeb.Live.Components.RunPanel do
  use DramatizerWeb, :html

  attr :runs, :list, default: []
  attr :attempts, :list, default: []
  attr :costs, :list, default: []

  def run_panel(assigns) do
    ~H"""
    <section class="run-panel" aria-labelledby="run-panel-title">
      <div class="section-heading compact">
        <div>
          <p class="eyebrow">TRACE</p>
          <h2 id="run-panel-title">运行与成本轨迹</h2>
        </div>
        <span class="count-pill">{length(@runs) + length(@attempts)}</span>
      </div>

      <div :if={@runs == [] and @attempts == []} class="empty-panel compact">
        <p>尚未执行 AI 或媒体任务。导入原著后，运行记录会在这里累积。</p>
      </div>

      <div class="trace-list">
        <article :for={run <- @runs} class="trace-row">
          <span class={["status-dot", "state-#{run_status(run.status)}"]}></span>
          <div>
            <strong>{run.definition_key}</strong>
            <p>工作流 · epoch {run.graph_epoch}</p>
          </div>
          <.state_badge state={run_status(run.status)} />
        </article>
        <article :for={attempt <- @attempts} class="trace-row">
          <span class={["status-dot", "state-#{attempt_status(attempt.status)}"]}></span>
          <div>
            <strong>{attempt.task_type || "生成任务"}</strong>
            <p>尝试 #{attempt.attempt_number} · {attempt.model || "未记录模型"}</p>
          </div>
          <.state_badge state={attempt_status(attempt.status)} />
        </article>
      </div>

      <div class="cost-strip">
        <span>实际成本</span>
        <strong>{format_cost(@costs)}</strong>
        <small>由已落账 CostEntry 汇总</small>
      </div>
    </section>
    """
  end

  defp run_status(status) when status in [:pending, :running], do: :loading
  defp run_status(:failed), do: :failed
  defp run_status(:succeeded), do: :ready
  defp run_status(_), do: :empty

  defp attempt_status(status) when status in [:prepared, :submitted, :unknown_remote_state],
    do: :loading

  defp attempt_status(status) when status in [:failed, :timed_out], do: :failed
  defp attempt_status(:succeeded), do: :ready
  defp attempt_status(_), do: :empty

  defp format_cost(costs) do
    micros =
      costs
      |> Enum.filter(&(&1.entry_type == :actual))
      |> Enum.reduce(0, &((&1.amount_micros || 0) + &2))

    "$" <> :erlang.float_to_binary(micros / 1_000_000, decimals: 6)
  end
end
