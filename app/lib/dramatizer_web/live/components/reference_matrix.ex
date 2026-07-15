defmodule DramatizerWeb.Live.Components.ReferenceMatrix do
  use DramatizerWeb, :html

  attr :slots, :list, default: []
  attr :candidates, :list, default: []
  attr :assets, :list, default: []

  def reference_matrix(assigns) do
    assigns = assign(assigns, :rows, Enum.map(assigns.slots, &row(&1, assigns.candidates)))

    ~H"""
    <section :if={@slots != []} class="reference-matrix" aria-labelledby="reference-matrix-title">
      <div class="section-heading compact">
        <div>
          <p class="eyebrow">REFERENCE MATRIX</p>
          <h3 id="reference-matrix-title">对象 × Variant × 参考槽位</h3>
          <p>逐槽位比较候选并明确主图；系统不会自动替你选择。</p>
        </div>
        <span class="count-pill">{length(@slots)} 个槽位</span>
      </div>

      <form id="reference-set-form" phx-submit="create-reference-set" class="reference-matrix__form">
        <article :for={row <- @rows} class="reference-matrix__row" data-reference-slot={row.slot}>
          <div class="reference-matrix__identity">
            <span class="eyebrow">{row.object_id}</span><strong>{row.variant_id}</strong><span>{slot_label(row.slot_name)}</span>
          </div>
          <div class="reference-matrix__candidates">
            <span :if={row.candidates == []} class="muted">尚未生成候选</span>
            <img
              :for={candidate <- Enum.take(row.candidates, 4)}
              src={candidate.image_url}
              alt={"#{row.slot_name} 候选 #{candidate.index + 1}"}
              class={candidate.selected && "is-selected"}
            />
          </div>
          <label class="form-field">
            <span>主参考图</span><select name={"reference[assignments][#{row.slot}]"}><option value="">请选择</option><option
              :for={asset <- @assets}
              value={asset.id}
              selected={row.selected_asset_id == asset.id}
            >{String.slice(asset.blob_hash, 0, 10)} · {asset.width}×{asset.height}</option></select>
          </label>
          <span class={["matrix-readiness", row.selected_asset_id && "is-ready"]}>
            {if row.selected_asset_id, do: "已选择", else: "等待选择"}
          </span>
        </article>
        <div class="form-actions">
          <button type="submit" class="btn btn-primary">创建 ReferenceSet 草稿</button>
        </div>
      </form>
    </section>
    """
  end

  defp row(slot, candidates) do
    [object_id, variant_id, slot_name] = String.split(slot, "/", parts: 3)
    grouped = Enum.filter(candidates, &(&1.slot_key == "reference:#{slot}"))
    selected = Enum.find(grouped, & &1.selected)

    %{
      slot: slot,
      object_id: object_id,
      variant_id: variant_id,
      slot_name: slot_name,
      candidates: grouped,
      selected_asset_id: selected && selected.asset.id
    }
  end

  defp slot_label("face_closeup"), do: "面部近景"
  defp slot_label("three_quarter_full"), do: "四分之三全身"
  defp slot_label("expression_features"), do: "表情特征"
  defp slot_label("spatial_wide"), do: "空间广角"
  defp slot_label("primary_direction"), do: "主方向"
  defp slot_label("key_lighting"), do: "关键照明"
  defp slot_label("overall"), do: "整体"
  defp slot_label("key_detail_state"), do: "关键细节状态"
  defp slot_label(value), do: value
end
