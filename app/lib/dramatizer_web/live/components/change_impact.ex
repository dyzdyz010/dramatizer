defmodule DramatizerWeb.Live.Components.ChangeImpact do
  use DramatizerWeb, :html

  attr :impact, :map, default: nil

  def change_impact(assigns) do
    groups =
      case assigns.impact do
        nil -> []
        impact -> impact.targets |> Enum.group_by(& &1.type) |> Enum.sort_by(&elem(&1, 0))
      end

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <article :if={@impact} class="change-impact" data-human-gate aria-labelledby="change-impact-title">
      <div class="section-heading compact">
        <div>
          <p class="eyebrow">CHANGE IMPACT · EPOCH {@impact.graph_epoch}</p>
          <h3 id="change-impact-title">确认精确影响范围</h3>
          <p>{authority_label(@impact.diff["kind"])} 权威从旧 Revision 切换到新 Revision。</p>
        </div>
        <span class="count-pill">{length(@impact.targets)} 个下游对象</span>
      </div>
      <div class="revision-comparison">
        <div>
          <span>旧 Revision</span><strong>{short(@impact.old_revision_id)}</strong><small>{short(@impact.diff["old_hash"])}</small>
        </div>
        <span>→</span>
        <div>
          <span>新 Revision</span><strong>{short(@impact.new_revision_id)}</strong><small>{short(@impact.diff["new_hash"])}</small>
        </div>
      </div>

      <form phx-submit="confirm-change" class="change-impact-form">
        <input type="hidden" name="change[present]" value="true" />
        <section :for={{type, targets} <- @groups} class="impact-group">
          <div class="impact-group__heading">
            <strong>{target_type_label(type)}</strong><span>{length(targets)} 项</span>
          </div>
          <label :for={target <- targets} class="impact-target">
            <input type="checkbox" name="change[target_ids][]" value={target.id} checked />
            <span>
              <strong>{target_label(target)}</strong><small>{short(target.id)}</small>
            </span>
            <em>{action_label(type)}</em>
          </label>
        </section>
        <div :if={@impact.targets == []} class="empty-panel compact">
          没有精确下游依赖；仍可冻结一个空影响 ChangeSet。
        </div>
        <div class="impact-confirmation">
          <p>只会调度勾选的对象。已提交的旧任务不会被删除，而会按旧输入完成并标为 stale。</p>
          <button type="submit" class="btn btn-primary">确认所选影响并创建 ChangeSet</button>
        </div>
      </form>
    </article>
    """
  end

  defp authority_label("narrative"), do: "Narrative"
  defp authority_label("visual_design"), do: "VisualDesign"
  defp authority_label("shot_plan"), do: "ShotPlan"
  defp authority_label(value), do: value

  defp target_type_label("generation_spec"), do: "生成规格"
  defp target_type_label("asset_version"), do: "生成素材"
  defp target_type_label("quality_report"), do: "质量证据"
  defp target_type_label("selection_decision"), do: "主图选择"
  defp target_type_label("attempt"), do: "执行尝试"
  defp target_type_label("node_run"), do: "分析节点"
  defp target_type_label(value), do: value

  defp target_label(target),
    do:
      "#{target_type_label(target.type)} · #{Map.get(target, :action, action_label(target.type))}"

  defp action_label("selection_decision"), do: "标记为待重新裁决"
  defp action_label("quality_report"), do: "重新校验"
  defp action_label("attempt"), do: "按状态收敛"
  defp action_label(_type), do: "重新计算"

  defp short(nil), do: "—"
  defp short(value), do: value |> to_string() |> String.slice(0, 12)
end
