defmodule DramatizerWeb.Live.Components.StageNav do
  use DramatizerWeb, :html

  @stages [
    {:source, "01", "原著"},
    {:analysis, "02", "解析"},
    {:episodes, "03", "剧集"},
    {:visuals, "04", "视觉"},
    {:shots, "05", "镜头"},
    {:timeline, "06", "时间线"},
    {:runs, "07", "运行记录"}
  ]

  attr :project, :map, required: true
  attr :current, :atom, required: true
  attr :states, :map, default: %{}

  def stage_nav(assigns) do
    assigns = assign(assigns, :stages, @stages)

    ~H"""
    <aside aria-label="制作阶段" class="stage-rail">
      <div class="stage-rail__heading">
        <span>PRODUCTION FLOW</span>
        <strong>制作阶段</strong>
      </div>
      <nav aria-label="制作阶段" class="stage-nav">
        <.link
          :for={{stage, number, label} <- @stages}
          navigate={stage_path(@project.id, stage)}
          class={["stage-nav__item", @current == stage && "is-active"]}
          aria-current={@current == stage && "page"}
          data-stage-state={Map.get(@states, stage, :empty)}
        >
          <span class="stage-nav__number">{number}</span>
          <span class="stage-nav__content">
            <span class="stage-nav__label">{label}</span>
            <small>{stage_state_label(Map.get(@states, stage, :empty))}</small>
          </span>
          <span
            class={["stage-nav__dot", "state-#{Map.get(@states, stage, :empty)}"]}
            aria-hidden="true"
          >
          </span>
        </.link>
      </nav>
    </aside>
    """
  end

  defp stage_state_label(:empty), do: "未开始"
  defp stage_state_label(:loading), do: "进行中"
  defp stage_state_label(:failed), do: "需要处理"
  defp stage_state_label(:ready), do: "已就绪"
  defp stage_state_label(:waiting_user), do: "等待确认"
  defp stage_state_label(:stale), do: "上游已变化"

  defp stage_path(project_id, :source), do: ~p"/projects/#{project_id}/source"
  defp stage_path(project_id, :analysis), do: ~p"/projects/#{project_id}/analysis"
  defp stage_path(project_id, :episodes), do: ~p"/projects/#{project_id}/episodes"
  defp stage_path(project_id, :visuals), do: ~p"/projects/#{project_id}/visuals"
  defp stage_path(project_id, :shots), do: ~p"/projects/#{project_id}/shots"
  defp stage_path(project_id, :timeline), do: ~p"/projects/#{project_id}/timeline"
  defp stage_path(project_id, :runs), do: ~p"/projects/#{project_id}/runs"
end
