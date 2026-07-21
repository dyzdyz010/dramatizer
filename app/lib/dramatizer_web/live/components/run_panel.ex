defmodule DramatizerWeb.Live.Components.RunPanel do
  use DramatizerWeb, :html

  attr :runs, :list, default: []
  attr :attempts, :list, default: []
  attr :costs, :list, default: []

  def run_panel(assigns) do
    assigns =
      assigns
      |> assign(
        :failed_attempts,
        Enum.filter(
          assigns.attempts,
          &(&1.status in [:failed, :timed_out, :unknown_remote_state])
        )
      )
      |> assign(
        :running_count,
        Enum.count(assigns.attempts, &(&1.status in [:prepared, :submitted]))
      )
      |> assign(:succeeded_count, Enum.count(assigns.attempts, &(&1.status == :succeeded)))

    ~H"""
    <section class="run-panel" aria-labelledby="run-panel-title">
      <div class="section-heading compact">
        <div>
          <p class="eyebrow">RUN CENTER</p>
          <h2 id="run-panel-title">运行、恢复与成本</h2>
          <p>每次 AI 外发都冻结模型配置、Prompt、输入哈希和 Attempt；失败不会覆盖历史。</p>
        </div>
        <span class="count-pill">{length(@runs) + length(@attempts)}</span>
      </div>

      <div class="run-summary">
        <div><span>执行中</span><strong>{@running_count}</strong></div>
        <div><span>已成功</span><strong>{@succeeded_count}</strong></div>
        <div><span>需处理</span><strong>{length(@failed_attempts)}</strong></div>
        <div><span>实际成本</span><strong>{format_cost(@costs)}</strong></div>
      </div>

      <div :if={@runs == [] and @attempts == []} class="empty-panel compact">
        <p>尚未执行 AI 或媒体任务。导入原著后，运行记录会在这里累积。</p>
      </div>

      <section :if={@runs != []} class="run-section">
        <div class="subsection-heading">
          <div><span class="eyebrow">WORKFLOWS</span><strong>持久化工作流</strong></div>
        </div>
        <div class="trace-list">
          <article :for={run <- @runs} class="trace-row run-row">
            <span class={["status-dot", "state-#{run_status(run.status)}"]}></span>
            <div>
              <strong>{workflow_label(run.definition_key)}</strong>
              <p>{run.definition_key} · 图 epoch {run.graph_epoch}</p>
              <small>{run_time(run)}</small>
            </div>
            <.state_badge state={run_status(run.status)} label={status_label(run.status)} />
          </article>
        </div>
      </section>

      <section :if={@attempts != []} class="run-section">
        <div class="subsection-heading">
          <div><span class="eyebrow">PROVIDER ATTEMPTS</span><strong>模型尝试</strong></div>
        </div>
        <div class="trace-list">
          <article :for={attempt <- @attempts} class="trace-row attempt-row">
            <span class={["status-dot", "state-#{attempt_status(attempt.status)}"]}></span>
            <div>
              <strong>{task_label(attempt.task_type)}</strong>
              <p>
                {attempt.adapter || "未记录 Provider"} · {attempt.model || "未记录模型"} · 尝试 {attempt.attempt_number}
              </p>
              <small>Spec {String.slice(attempt.spec_id, 0, 12)}</small>
            </div>
            <div class="attempt-result">
              <span :if={attempt.error_code} class="error-chip">
                {error_label(attempt.error_code)}
              </span>
              <.state_badge
                state={attempt_status(attempt.status)}
                label={status_label(attempt.status)}
              />
            </div>
          </article>
        </div>
      </section>

      <section :if={@failed_attempts != []} class="recovery-list">
        <div class="subsection-heading">
          <div><span class="eyebrow">RECOVERY</span><strong>待恢复任务</strong></div>
        </div>
        <article :for={attempt <- @failed_attempts} class="recovery-card">
          <div>
            <strong>{task_label(attempt.task_type)} · 尝试 {attempt.attempt_number}</strong>
            <p>{error_label(attempt.error_code)}</p>
            <small>{recovery_guidance(attempt)}</small>
          </div>
        </article>
      </section>

      <div class="cost-strip">
        <span>已结算实际成本</span><strong>{format_cost(@costs)}</strong><small>{cost_note(@costs)}</small>
      </div>
    </section>
    """
  end

  defp run_status(:pending), do: :queued
  defp run_status(:running), do: :loading
  defp run_status(:failed), do: :failed
  defp run_status(:succeeded), do: :ready
  defp run_status(_), do: :empty

  defp attempt_status(:prepared), do: :queued
  defp attempt_status(:submitted), do: :loading
  defp attempt_status(:unknown_remote_state), do: :unknown

  defp attempt_status(status) when status in [:failed, :timed_out], do: :failed
  defp attempt_status(:succeeded), do: :ready
  defp attempt_status(_), do: :empty

  defp workflow_label("whole_novel_analysis_v1"), do: "整本小说分析"
  defp workflow_label(value), do: value
  defp task_label("narrative_proposal"), do: "分集叙事提案"
  defp task_label("visual_design_proposal"), do: "视觉设计提案"
  defp task_label("directing_proposal"), do: "导演方案提案"
  defp task_label("reference_image"), do: "参考图生成"
  defp task_label("shot_keyframe"), do: "镜头主图生成"
  defp task_label("image_edit"), do: "图像编辑"
  defp task_label(value), do: value || "生成任务"

  defp status_label(:pending), do: "等待"
  defp status_label(:prepared), do: "已准备"
  defp status_label(:submitted), do: "Provider 执行中"
  defp status_label(:running), do: "执行中"
  defp status_label(:succeeded), do: "成功"
  defp status_label(:failed), do: "失败"
  defp status_label(:timed_out), do: "超时"
  defp status_label(:unknown_remote_state), do: "远端状态未知"
  defp status_label(status), do: to_string(status)

  defp error_label(nil), do: "未记录错误码"
  defp error_label("provider_rejected"), do: "Provider 拒绝了请求，可调整输入后重试"
  defp error_label("structured_validation_failed"), do: "模型输出未通过结构校验"
  defp error_label("invalid_proposal_output"), do: "提案字段不完整或类型错误"
  defp error_label("unknown_remote_state"), do: "远端可能已接收请求；禁止自动重提，请人工核对"
  defp error_label(value), do: value

  defp recovery_guidance(%{status: :unknown_remote_state}),
    do: "先在 Provider 侧核对是否已产生结果；系统不会自动重提或创建新 Attempt。"

  defp recovery_guidance(_attempt),
    do: "返回对应工作台点击“再次生成”；系统会建立新 Attempt，并保留这条失败证据。"

  defp run_time(run) do
    cond do
      run.completed_at -> "完成于 #{Calendar.strftime(run.completed_at, "%m-%d %H:%M:%S")}"
      run.started_at -> "开始于 #{Calendar.strftime(run.started_at, "%m-%d %H:%M:%S")}"
      true -> "尚未开始"
    end
  end

  defp cost_note(costs) do
    actuals = Enum.filter(costs, &(&1.entry_type == :actual))
    "#{length(actuals)} 笔实际费用；未返回金额的调用仍保留账目记录"
  end

  defp format_cost(costs) do
    actuals = Enum.filter(costs, &(&1.entry_type == :actual))
    known = Enum.filter(actuals, &is_integer(&1.amount_micros))
    unknown? = Enum.any?(actuals, &is_nil(&1.amount_micros))
    micros = Enum.reduce(known, 0, &(&1.amount_micros + &2))
    formatted = "$" <> :erlang.float_to_binary(micros / 1_000_000, decimals: 6)

    cond do
      unknown? and known == [] -> "实际费用未返回"
      unknown? -> formatted <> " + 未返回项"
      true -> formatted
    end
  end
end
