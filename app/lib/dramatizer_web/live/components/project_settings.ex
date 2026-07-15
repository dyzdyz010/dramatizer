defmodule DramatizerWeb.Live.Components.ProjectSettings do
  use DramatizerWeb, :html

  attr :profile, :map, required: true
  attr :budget, :map, required: true
  attr :model_task_types, :list, required: true
  attr :prompt_task_types, :list, required: true

  def project_settings(assigns) do
    ~H"""
    <section class="settings-grid" aria-labelledby="project-settings-title">
      <div class="section-heading compact">
        <div>
          <p class="eyebrow">PROJECT SETTINGS</p>
          <h2 id="project-settings-title">项目设置</h2>
        </div>
      </div>

      <form
        id="production-profile-form"
        phx-submit="update-production-profile"
        class="structured-form"
      >
        <h3>制作规格</h3>
        <p class="form-help">项目默认值会在新 Revision 或 Run 中冻结；历史输入不会被回写。</p>
        <div class="settings-fields">
          <label :for={{field, label, unit} <- production_profile_fields()}>
            <span>{label}</span>
            <div class="input-with-unit">
              <input type="number" min="1" name={"profile[#{field}]"} value={@profile[field]} />
              <small>{unit}</small>
            </div>
          </label>
        </div>
        <button type="submit" class="btn btn-soft">保存项目规格</button>
      </form>

      <form id="model-override-form" phx-submit="put-model-override" class="structured-form">
        <h3>模型项目覆盖</h3>
        <p class="form-help">留空字段继承系统默认；具体 AI 动作还可以设置仅本次有效的覆盖。</p>
        <div class="settings-form-grid">
          <label>
            <span>任务类型</span>
            <select name="model_override[task_type]">
              <option :for={task <- @model_task_types} value={task}>{task_label(task)}</option>
            </select>
          </label>
          <label>
            <span>模型</span>
            <input type="text" name="model_override[model]" placeholder="留空继承系统值" />
          </label>
          <label>
            <span>推理强度</span>
            <select name="model_override[reasoning_effort]">
              <option value="">继承</option>
              <option :for={effort <- ~w(minimal low medium high)} value={effort}>{effort}</option>
            </select>
          </label>
          <label>
            <span>图片质量</span>
            <select name="model_override[quality]">
              <option value="">继承</option>
              <option :for={quality <- ~w(low medium high)} value={quality}>{quality}</option>
            </select>
          </label>
          <label>
            <span>图片尺寸</span>
            <input type="text" name="model_override[size]" placeholder="768x1360" />
          </label>
          <label>
            <span>候选数量</span>
            <input type="number" min="1" name="model_override[candidate_count]" placeholder="继承" />
          </label>
        </div>
        <div class="form-actions split-actions">
          <button type="submit" name="_action" value="delete" class="btn btn-ghost">恢复继承</button>
          <button type="submit" class="btn btn-soft">保存模型覆盖</button>
        </div>
      </form>

      <form id="budget-form" phx-submit="update-budget" class="structured-form">
        <h3>项目预算</h3>
        <p class="form-help">留空表示不设上限但仍持续记账；余额不足只会在外发前阻断。</p>
        <label>
          <span>预算上限（美元）</span>
          <input
            type="number"
            min="0"
            step="0.000001"
            name="budget[limit_units]"
            value={format_budget(@budget.limit_micros)}
            placeholder="不设上限"
          />
        </label>
        <div class="budget-projection">
          <span>已预留 {format_money(@budget.reserved_micros)}</span>
          <span>已结算 {format_money(@budget.actual_micros)}</span>
        </div>
        <button type="submit" class="btn btn-soft">保存预算</button>
      </form>

      <form id="prompt-appendix-form" phx-submit="create-prompt-appendix" class="structured-form">
        <h3>创作附加要求</h3>
        <p class="form-help">核心 Prompt 由系统隐藏并版本化；这里仅追加当前任务的项目规则。</p>
        <label>
          <span>任务类型</span>
          <select name="prompt_appendix[task_type]">
            <option :for={task <- @prompt_task_types} value={task}>{task_label(task)}</option>
          </select>
        </label>
        <label>
          <span>Appendix 内容</span>
          <textarea name="prompt_appendix[body]" rows="6" required></textarea>
        </label>
        <button type="submit" class="btn btn-soft">保存新 Appendix Revision</button>
      </form>
    </section>
    """
  end

  defp production_profile_fields do
    [
      {:aspect_width, "画幅宽比", "份"},
      {:aspect_height, "画幅高比", "份"},
      {:duration_min_seconds, "目标最短时长", "秒"},
      {:duration_max_seconds, "目标最长时长", "秒"},
      {:shot_min, "目标最少镜头", "个"},
      {:shot_max, "目标最多镜头", "个"},
      {:preview_width, "预览宽度", "px"},
      {:preview_height, "预览高度", "px"},
      {:formal_width, "正式宽度", "px"},
      {:formal_height, "正式高度", "px"}
    ]
  end

  defp task_label("people_relations"), do: "人物、别名与关系"
  defp task_label("places_props_world"), do: "地点、道具与世界"
  defp task_label("events_timeline"), do: "事件与时间线"
  defp task_label("entity_merge"), do: "实体归并"
  defp task_label("episode_candidates"), do: "候选分集"
  defp task_label("conflict_check"), do: "冲突校验"
  defp task_label("directing_proposal"), do: "导演提案"
  defp task_label("image_prompt"), do: "图像提示词"
  defp task_label("reference_image"), do: "参考图生成"
  defp task_label("shot_keyframe"), do: "镜头关键帧"
  defp task_label("image_edit"), do: "图像编辑"
  defp task_label("semantic_qc"), do: "语义质量检查"
  defp task_label(task), do: task

  defp format_budget(nil), do: nil
  defp format_budget(micros), do: :erlang.float_to_binary(micros / 1_000_000, decimals: 6)
  defp format_money(nil), do: "未返回"
  defp format_money(micros), do: "$" <> :erlang.float_to_binary(micros / 1_000_000, decimals: 6)
end
