defmodule DramatizerWeb.Live.Components.VisualDesignEditor do
  use DramatizerWeb, :html

  alias DramatizerWeb.Forms.VisualDesignDraftForm

  attr :draft, :map, required: true

  def visual_design_editor(assigns) do
    payload =
      assigns.draft.payload
      |> VisualDesignDraftForm.from_payload()
      |> Map.put_new("objects", [])

    assigns =
      assigns
      |> assign(:payload, payload)
      |> assign(:counts, object_counts(payload["objects"]))

    ~H"""
    <article class="authority-editor visual-design-editor" data-visual-design-editor>
      <div class="section-heading compact">
        <div>
          <p class="eyebrow">VISUAL DESIGN AUTHORITY · DRAFT</p>
          <h3>视觉对象与参考策略</h3>
          <p>角色、场景、道具先成为视觉权威，再据此生成不可变参考候选。</p>
        </div>
        <span class={status_class(@draft.status)}>{status_label(@draft.status)}</span>
      </div>

      <nav class="object-type-tabs" aria-label="视觉对象类型">
        <span>角色 <strong>{@counts["character"]}</strong></span>
        <span>场景 <strong>{@counts["location"]}</strong></span>
        <span>道具 <strong>{@counts["prop"]}</strong></span>
      </nav>

      <form
        :if={@draft.status == :editing}
        id={"visual-design-draft-#{@draft.id}"}
        phx-submit="save-visual-design-draft"
        phx-value-id={@draft.id}
        class="authority-form"
      >
        <div class="panel-actions visual-add-actions">
          <span>新增视觉对象</span>
          <button
            :for={{type, label} <- type_options()}
            type="button"
            class="btn btn-soft"
            phx-click="add-visual-item"
            phx-value-id={@draft.id}
            phx-value-collection="objects"
            phx-value-type={type}
          >
            ＋ {label}
          </button>
        </div>

        <article
          :for={{object, object_index} <- Enum.with_index(@payload["objects"])}
          class={["visual-object-card", "type-#{object["type"]}"]}
        >
          <div class="visual-object-card__heading">
            <div class="object-identity">
              <span class="object-type-icon">{type_icon(object["type"])}</span>
              <div>
                <span class="eyebrow">{type_label(object["type"])} · {object["id"]}</span>
                <h4>{object["name"]}</h4>
              </div>
            </div>
            <.item_controls draft_id={@draft.id} collection="objects" item_id={object["id"]} />
          </div>

          <input
            type="hidden"
            name={"visual_design[objects][#{object_index}][id]"}
            value={object["id"]}
          />
          <div class="field-grid three-up">
            <label class="form-field">
              <span>类型</span><select name={"visual_design[objects][#{object_index}][type]"}><option
                :for={{value, label} <- type_options()}
                value={value}
                selected={object["type"] == value}
              >{label}</option></select>
            </label>
            <.text_field
              name={"visual_design[objects][#{object_index}][name]"}
              label="名称"
              value={object["name"]}
            />
            <.text_field
              name={"visual_design[objects][#{object_index}][narrative_role]"}
              label="叙事作用"
              value={object["narrative_role"]}
            />
          </div>
          <.area_field
            name={"visual_design[objects][#{object_index}][description]"}
            label="视觉定义"
            value={object["description"]}
          />

          <div class="field-grid three-up">
            <label class="form-field">
              <span>重要性</span><select name={"visual_design[objects][#{object_index}][importance]"}><option
                :for={{value, label} <- importance_options()}
                value={value}
                selected={object["importance"] == value}
              >{label}</option></select>
            </label>
            <.semantics_field
              name={"visual_design[objects][#{object_index}][source_semantics]"}
              value={object["source_semantics"]}
            />
            <div class="flag-fieldset">
              <.check_field
                name={"visual_design[objects][#{object_index}][recurring]"}
                label="反复出现"
                checked={object["recurring"]}
              />
              <.check_field
                name={"visual_design[objects][#{object_index}][key]"}
                label="关键对象"
                checked={object["key"]}
              />
              <.check_field
                name={"visual_design[objects][#{object_index}][reference_required]"}
                label="需要主参考图"
                checked={object["reference_required"]}
              />
            </div>
          </div>

          <div class="type-detail-panel">
            <span class="eyebrow">{type_label(object["type"])}专属细节</span>
            <div class="field-grid three-up">
              <.text_field
                :for={{field, label} <- type_fields(object["type"])}
                name={"visual_design[objects][#{object_index}][type_details][#{field}]"}
                label={label}
                value={get_in(object, ["type_details", field])}
              />
            </div>
          </div>

          <div class="field-grid two-up">
            <.area_field
              name={"visual_design[objects][#{object_index}][palette]"}
              label="色板（逗号或换行）"
              value={object["palette"]}
            />
            <.area_field
              name={"visual_design[objects][#{object_index}][materials]"}
              label="材质（逗号或换行）"
              value={object["materials"]}
            />
            <.area_field
              name={"visual_design[objects][#{object_index}][must_show]"}
              label="必须出现"
              value={object["must_show"]}
            />
            <.area_field
              name={"visual_design[objects][#{object_index}][must_not_show]"}
              label="禁止出现"
              value={object["must_not_show"]}
            />
          </div>

          <div class="subsection-heading">
            <div><span class="eyebrow">VISUAL VARIANT</span><strong>视觉 Variant</strong></div>
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="add-visual-item"
              phx-value-id={@draft.id}
              phx-value-collection={"variants:#{object["id"]}"}
            >
              ＋ 新增 Variant
            </button>
          </div>
          <div class="variant-grid">
            <article
              :for={{variant, variant_index} <- Enum.with_index(object["variants"] || [])}
              class="variant-card"
            >
              <div class="variant-card__heading">
                <span>V{variant_index + 1}</span>
                <.item_controls
                  draft_id={@draft.id}
                  collection={"variants:#{object["id"]}"}
                  item_id={variant["id"]}
                  compact
                />
              </div>
              <input
                type="hidden"
                name={"visual_design[objects][#{object_index}][variants][#{variant_index}][id]"}
                value={variant["id"]}
              />
              <.text_field
                name={"visual_design[objects][#{object_index}][variants][#{variant_index}][name]"}
                label="Variant 名称"
                value={variant["name"]}
              />
              <.area_field
                name={"visual_design[objects][#{object_index}][variants][#{variant_index}][state_description]"}
                label="状态描述"
                value={variant["state_description"]}
              />
              <div class="field-grid two-up">
                <.text_field
                  name={"visual_design[objects][#{object_index}][variants][#{variant_index}][wardrobe]"}
                  label="服装/表面状态"
                  value={variant["wardrobe"]}
                />
                <.text_field
                  name={"visual_design[objects][#{object_index}][variants][#{variant_index}][lighting]"}
                  label="照明状态"
                  value={variant["lighting"]}
                />
              </div>
              <.area_field
                name={"visual_design[objects][#{object_index}][variants][#{variant_index}][required_slots]"}
                label="参考槽位（可编辑）"
                value={variant["required_slots"]}
              />
            </article>
          </div>
        </article>

        <footer class="sticky-form-actions">
          <span>确认后才能生成正式参考候选</span>
          <div>
            <button type="submit" class="btn btn-soft">保存 Draft</button><button
              type="button"
              class="btn btn-primary"
              phx-click="confirm-draft"
              phx-value-id={@draft.id}
            >确认并冻结 Revision</button>
          </div>
        </footer>
      </form>

      <div :if={@draft.status == :confirmed} class="confirmed-authority-summary">
        <div><span>角色</span><strong>{@counts["character"]}</strong></div>
        <div><span>场景</span><strong>{@counts["location"]}</strong></div>
        <div><span>道具</span><strong>{@counts["prop"]}</strong></div>
        <div>
          <span>需要参考</span><strong>{Enum.count(@payload["objects"], & &1["reference_required"])}</strong>
        </div>
      </div>
      <button
        :if={@draft.status == :confirmed and @draft.confirmed_revision_id}
        type="button"
        class="btn btn-ghost"
        phx-click="derive-draft"
        phx-value-revision-id={@draft.confirmed_revision_id}
      >
        从此 Revision 派生修改
      </button>
    </article>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: ""

  defp text_field(assigns) do
    ~H"""
    <label class="form-field">
      <span>{@label}</span> <input type="text" name={@name} value={@value || ""} />
    </label>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: ""

  defp area_field(assigns) do
    ~H"""
    <label class="form-field">
      <span>{@label}</span><textarea name={@name} rows="3">{@value || ""}</textarea>
    </label>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :checked, :boolean, default: false

  defp check_field(assigns) do
    ~H"""
    <label class="check-field">
      <input type="hidden" name={@name} value="false" /><input
        type="checkbox"
        name={@name}
        value="true"
        checked={@checked}
      /><span>{@label}</span>
    </label>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, default: "source_grounded"

  defp semantics_field(assigns) do
    ~H"""
    <label class="form-field">
      <span>来源语义</span><select name={@name}><option
        :for={{value, label} <- semantics_options()}
        value={value}
        selected={@value == value}
      >{label}</option></select>
    </label>
    """
  end

  attr :draft_id, :string, required: true
  attr :collection, :string, required: true
  attr :item_id, :string, required: true
  attr :compact, :boolean, default: false

  defp item_controls(assigns) do
    ~H"""
    <div class={["item-controls", @compact && "is-compact"]}>
      <button
        type="button"
        aria-label="上移"
        phx-click="move-visual-item"
        phx-value-id={@draft_id}
        phx-value-collection={@collection}
        phx-value-item-id={@item_id}
        phx-value-direction="up"
      >
        ↑
      </button>
      <button
        type="button"
        aria-label="下移"
        phx-click="move-visual-item"
        phx-value-id={@draft_id}
        phx-value-collection={@collection}
        phx-value-item-id={@item_id}
        phx-value-direction="down"
      >
        ↓
      </button>
      <button
        type="button"
        aria-label="删除"
        class="danger"
        phx-click="remove-visual-item"
        phx-value-id={@draft_id}
        phx-value-collection={@collection}
        phx-value-item-id={@item_id}
      >
        ×
      </button>
    </div>
    """
  end

  defp object_counts(objects),
    do:
      Map.new(
        ~w(character location prop),
        &{&1, Enum.count(objects, fn object -> object["type"] == &1 end)}
      )

  defp type_options, do: [{"character", "角色"}, {"location", "场景"}, {"prop", "道具"}]
  defp type_label(type), do: type_options() |> Map.new() |> Map.get(type, "对象")
  defp type_icon("character"), do: "人"
  defp type_icon("location"), do: "景"
  defp type_icon("prop"), do: "物"
  defp type_icon(_), do: "视"
  defp importance_options, do: [{"background", "背景"}, {"supporting", "重要"}, {"key", "关键"}]

  defp semantics_options,
    do: [{"source_grounded", "原文明确"}, {"inferred", "合理推断"}, {"creative", "创作补充"}]

  defp type_fields("character"),
    do: [{"age_and_build", "年龄与体态"}, {"face_and_hair", "面部与发型"}, {"silhouette", "识别轮廓"}]

  defp type_fields("location"),
    do: [{"architecture", "建筑语言"}, {"spatial_layout", "空间关系"}, {"atmosphere", "环境氛围"}]

  defp type_fields("prop"),
    do: [{"scale", "尺度"}, {"condition", "状态"}, {"functional_detail", "功能细节"}]

  defp type_fields(_), do: []
  defp status_label(:editing), do: "等待确认"
  defp status_label(:confirmed), do: "已冻结"
  defp status_class(status), do: ["authority-status", "status-#{status}"]
end
