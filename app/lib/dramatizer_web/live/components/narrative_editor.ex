defmodule DramatizerWeb.Live.Components.NarrativeEditor do
  use DramatizerWeb, :html

  alias DramatizerWeb.Forms.NarrativeDraftForm

  attr :draft, :map, required: true

  def narrative_editor(assigns) do
    assigns = assign(assigns, :payload, normalized_payload(assigns.draft.payload))

    ~H"""
    <article class="authority-editor narrative-editor" data-narrative-editor>
      <div class="section-heading compact">
        <div>
          <p class="eyebrow">NARRATIVE AUTHORITY · DRAFT</p>
          <h3>分集制作稿</h3>
          <p>保存只更新 Draft；只有“确认并冻结”才会建立不可变 Revision。</p>
        </div>
        <span class={status_class(@draft.status)}>{status_label(@draft.status)}</span>
      </div>

      <form
        :if={@draft.status == :editing}
        id={"narrative-draft-#{@draft.id}"}
        phx-submit="save-narrative-draft"
        phx-value-id={@draft.id}
        class="authority-form"
      >
        <section class="form-section" aria-labelledby={"episode-overview-#{@draft.id}"}>
          <div class="form-section__heading">
            <div>
              <span class="eyebrow">EPISODE</span>
              <h4 id={"episode-overview-#{@draft.id}"}>分集概览</h4>
            </div>
          </div>
          <input type="hidden" name="narrative[episode][id]" value={@payload["episode"]["id"]} />
          <div class="field-grid two-up">
            <.text_field
              name="narrative[episode][title]"
              label="标题"
              value={@payload["episode"]["title"]}
            />
            <.text_field
              name="narrative[episode][logline]"
              label="一句话梗概"
              value={@payload["episode"]["logline"]}
            />
          </div>
          <.area_field
            name="narrative[episode][summary]"
            label="剧情梗概"
            value={@payload["episode"]["summary"]}
          />
          <div class="field-grid three-up">
            <.area_field
              name="narrative[episode][opening_hook]"
              label="开场钩子"
              value={@payload["episode"]["opening_hook"]}
            />
            <.area_field
              name="narrative[episode][central_conflict]"
              label="核心冲突"
              value={@payload["episode"]["central_conflict"]}
            />
            <.area_field
              name="narrative[episode][ending_hook]"
              label="结尾钩子"
              value={@payload["episode"]["ending_hook"]}
            />
          </div>
        </section>

        <section class="form-section production-override">
          <div class="form-section__heading">
            <div>
              <span class="eyebrow">EPISODE OVERRIDE</span>
              <h4>本集制作规格覆盖</h4>
              <p>留空继承项目默认值；确认时写入 Revision 快照。</p>
            </div>
          </div>
          <div class="field-grid three-up">
            <.number_field
              :for={{field, label} <- profile_fields()}
              name={"narrative[production_profile_override][#{field}]"}
              label={label}
              value={@payload["production_profile_override"][field]}
            />
          </div>
        </section>

        <section class="form-section">
          <div class="form-section__heading">
            <div>
              <span class="eyebrow">SCENE & BEAT</span>
              <h4>Scene 与 Beat</h4>
            </div>
            <button
              type="button"
              class="btn btn-soft"
              phx-click="add-narrative-item"
              phx-value-id={@draft.id}
              phx-value-collection="scenes"
            >
              ＋ 新增 Scene
            </button>
          </div>

          <article
            :for={{scene, scene_index} <- Enum.with_index(@payload["scenes"] || [])}
            class="nested-form-card scene-card"
          >
            <div class="nested-form-card__heading">
              <div>
                <span class="eyebrow">SCENE {pad(scene_index + 1)}</span>
                <h5>{scene["title"] || scene["id"]}</h5>
              </div>
              <.item_controls draft_id={@draft.id} collection="scenes" item_id={scene["id"]} />
            </div>
            <input type="hidden" name={"narrative[scenes][#{scene_index}][id]"} value={scene["id"]} />
            <div class="field-grid three-up">
              <.text_field
                name={"narrative[scenes][#{scene_index}][title]"}
                label="Scene 标题"
                value={scene["title"]}
              />
              <.text_field
                name={"narrative[scenes][#{scene_index}][location_ref]"}
                label="地点引用"
                value={scene["location_ref"]}
              />
              <.text_field
                name={"narrative[scenes][#{scene_index}][time_of_day]"}
                label="时间"
                value={scene["time_of_day"]}
              />
            </div>
            <.area_field
              name={"narrative[scenes][#{scene_index}][goal]"}
              label="场景目标"
              value={scene["goal"]}
            />
            <.area_field
              name={"narrative[scenes][#{scene_index}][summary]"}
              label="场景内容"
              value={scene["summary"]}
            />
            <.semantics_field
              name={"narrative[scenes][#{scene_index}][source_semantics]"}
              value={scene["source_semantics"]}
            />

            <div class="subsection-heading">
              <strong>Beat 节拍</strong>
              <button
                type="button"
                class="btn btn-ghost"
                phx-click="add-narrative-item"
                phx-value-id={@draft.id}
                phx-value-collection={"beats:#{scene["id"]}"}
              >
                ＋ 新增 Beat
              </button>
            </div>
            <article
              :for={{beat, beat_index} <- Enum.with_index(scene["beats"] || [])}
              class="beat-row"
            >
              <div class="beat-row__number">B{beat_index + 1}</div>
              <div class="beat-row__fields">
                <input
                  type="hidden"
                  name={"narrative[scenes][#{scene_index}][beats][#{beat_index}][id]"}
                  value={beat["id"]}
                />
                <div class="field-grid two-up">
                  <.text_field
                    name={"narrative[scenes][#{scene_index}][beats][#{beat_index}][title]"}
                    label="Beat 标题"
                    value={beat["title"]}
                  />
                  <.text_field
                    name={"narrative[scenes][#{scene_index}][beats][#{beat_index}][story_event_ids]"}
                    label="关联事件 ID"
                    value={beat["story_event_ids"]}
                  />
                </div>
                <.area_field
                  name={"narrative[scenes][#{scene_index}][beats][#{beat_index}][goal]"}
                  label="呈现目标"
                  value={beat["goal"]}
                />
                <.area_field
                  name={"narrative[scenes][#{scene_index}][beats][#{beat_index}][summary]"}
                  label="动作与变化"
                  value={beat["summary"]}
                />
              </div>
              <.item_controls
                draft_id={@draft.id}
                collection={"beats:#{scene["id"]}"}
                item_id={beat["id"]}
                compact
              />
            </article>
          </article>
        </section>

        <section class="form-section">
          <div class="form-section__heading">
            <div>
              <span class="eyebrow">STORY EVENTS</span>
              <h4>StoryEvent</h4>
            </div>
            <button
              type="button"
              class="btn btn-soft"
              phx-click="add-narrative-item"
              phx-value-id={@draft.id}
              phx-value-collection="story_events"
            >
              ＋ 新增事件
            </button>
          </div>
          <article
            :for={{event, index} <- Enum.with_index(@payload["story_events"] || [])}
            class="nested-form-card compact-card"
          >
            <div class="nested-form-card__heading">
              <span class="eyebrow">EVENT {pad(index + 1)}</span>
              <.item_controls draft_id={@draft.id} collection="story_events" item_id={event["id"]} />
            </div>
            <input type="hidden" name={"narrative[story_events][#{index}][id]"} value={event["id"]} />
            <div class="field-grid two-up">
              <.text_field
                name={"narrative[story_events][#{index}][name]"}
                label="事件名"
                value={event["name"]}
              />
              <.text_field
                name={"narrative[story_events][#{index}][subject_refs]"}
                label="参与对象"
                value={event["subject_refs"]}
              />
            </div>
            <.area_field
              name={"narrative[story_events][#{index}][description]"}
              label="事件描述"
              value={event["description"]}
            />
            <.semantics_field
              name={"narrative[story_events][#{index}][source_semantics]"}
              value={event["source_semantics"]}
            />
          </article>
        </section>

        <section class="form-section">
          <div class="form-section__heading">
            <div>
              <span class="eyebrow">DIALOGUE</span>
              <h4>DialogueEvent</h4>
            </div>
            <button
              type="button"
              class="btn btn-soft"
              phx-click="add-narrative-item"
              phx-value-id={@draft.id}
              phx-value-collection="dialogue_events"
            >
              ＋ 新增对白
            </button>
          </div>
          <article
            :for={{dialogue, index} <- Enum.with_index(@payload["dialogue_events"] || [])}
            class="nested-form-card compact-card"
          >
            <div class="nested-form-card__heading">
              <span class="eyebrow">DIALOGUE {pad(index + 1)}</span>
              <.item_controls
                draft_id={@draft.id}
                collection="dialogue_events"
                item_id={dialogue["id"]}
              />
            </div>
            <input
              type="hidden"
              name={"narrative[dialogue_events][#{index}][id]"}
              value={dialogue["id"]}
            />
            <div class="field-grid three-up">
              <.text_field
                name={"narrative[dialogue_events][#{index}][speaker_ref]"}
                label="说话人"
                value={dialogue["speaker_ref"]}
              />
              <.text_field
                name={"narrative[dialogue_events][#{index}][scene_id]"}
                label="Scene ID"
                value={dialogue["scene_id"]}
              />
              <.text_field
                name={"narrative[dialogue_events][#{index}][beat_id]"}
                label="Beat ID"
                value={dialogue["beat_id"]}
              />
              <.text_field
                name={"narrative[dialogue_events][#{index}][story_event_id]"}
                label="StoryEvent ID"
                value={dialogue["story_event_id"]}
              />
              <.number_field
                name={"narrative[dialogue_events][#{index}][start_ms]"}
                label="开始 ms"
                value={dialogue["start_ms"]}
              />
              <.number_field
                name={"narrative[dialogue_events][#{index}][end_ms]"}
                label="结束 ms"
                value={dialogue["end_ms"]}
              />
            </div>
            <.area_field
              name={"narrative[dialogue_events][#{index}][text]"}
              label="对白内容"
              value={dialogue["text"]}
            />
            <.semantics_field
              name={"narrative[dialogue_events][#{index}][source_semantics]"}
              value={dialogue["source_semantics"]}
            />
          </article>
        </section>

        <div class="field-grid two-up">
          <.simple_collection
            title="制作依赖"
            code="DEPENDENCIES"
            items={@payload["dependencies"] || []}
            collection="dependencies"
            draft_id={@draft.id}
            fields={[:name, :kind, :source_semantics]}
          />
          <.simple_collection
            title="冲突与待决项"
            code="CONFLICTS"
            items={@payload["conflicts"] || []}
            collection="conflicts"
            draft_id={@draft.id}
            fields={[:description, :severity]}
          />
        </div>

        <footer class="sticky-form-actions">
          <span>修改尚未成为权威</span>
          <div>
            <button type="submit" class="btn btn-soft">保存 Draft</button>
            <button
              type="button"
              class="btn btn-primary"
              phx-click="confirm-draft"
              phx-value-id={@draft.id}
            >
              确认并冻结 Revision
            </button>
          </div>
        </footer>
      </form>

      <div :if={@draft.status == :confirmed} class="confirmed-authority-summary">
        <div><span>标题</span><strong>{@payload["episode"]["title"]}</strong></div>
        <div><span>Scene</span><strong>{length(@payload["scenes"] || [])}</strong></div>
        <div><span>StoryEvent</span><strong>{length(@payload["story_events"] || [])}</strong></div>
        <div>
          <span>DialogueEvent</span><strong>{length(@payload["dialogue_events"] || [])}</strong>
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
  attr :value, :any, default: nil

  defp number_field(assigns) do
    ~H"""
    <label class="form-field">
      <span>{@label}</span> <input type="number" name={@name} value={@value} />
    </label>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, default: "source_grounded"

  defp semantics_field(assigns) do
    ~H"""
    <label class="form-field compact-field">
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
        phx-click="move-narrative-item"
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
        phx-click="move-narrative-item"
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
        phx-click="remove-narrative-item"
        phx-value-id={@draft_id}
        phx-value-collection={@collection}
        phx-value-item-id={@item_id}
      >
        ×
      </button>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :code, :string, required: true
  attr :items, :list, required: true
  attr :collection, :string, required: true
  attr :draft_id, :string, required: true
  attr :fields, :list, required: true

  defp simple_collection(assigns) do
    ~H"""
    <section class="form-section simple-collection">
      <div class="form-section__heading">
        <div>
          <span class="eyebrow">{@code}</span>
          <h4>{@title}</h4>
        </div>
        <button
          type="button"
          class="btn btn-ghost"
          phx-click="add-narrative-item"
          phx-value-id={@draft_id}
          phx-value-collection={@collection}
        >
          ＋ 新增
        </button>
      </div>
      <article :for={{item, index} <- Enum.with_index(@items)} class="simple-collection__row">
        <input type="hidden" name={"narrative[#{@collection}][#{index}][id]"} value={item["id"]} />
        <.text_field
          :for={field <- @fields}
          name={"narrative[#{@collection}][#{index}][#{field}]"}
          label={field_label(field)}
          value={simple_value(item, field)}
        />
        <.item_controls draft_id={@draft_id} collection={@collection} item_id={item["id"]} compact />
      </article>
      <div :if={@items == []} class="empty-panel compact">暂无条目。</div>
    </section>
    """
  end

  defp simple_value(item, field), do: item[to_string(field)] || ""
  defp field_label(:name), do: "名称"
  defp field_label(:kind), do: "类型"
  defp field_label(:source_semantics), do: "来源语义"
  defp field_label(:description), do: "说明"
  defp field_label(:severity), do: "级别"

  defp profile_fields do
    [
      {"aspect_width", "画幅宽"},
      {"aspect_height", "画幅高"},
      {"duration_min_seconds", "最短秒数"},
      {"duration_max_seconds", "最长秒数"},
      {"shot_min", "最少镜头"},
      {"shot_max", "最多镜头"}
    ]
  end

  defp semantics_options,
    do: [{"source_grounded", "原文明确"}, {"inferred", "合理推断"}, {"creative", "创作补充"}]

  defp status_label(:editing), do: "等待确认"
  defp status_label(:confirmed), do: "已冻结"
  defp status_class(status), do: ["authority-status", "status-#{status}"]
  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp normalized_payload(payload) do
    payload
    |> NarrativeDraftForm.from_payload()
    |> Map.put_new("episode", %{})
    |> Map.put_new("scenes", [])
    |> Map.put_new("story_events", [])
    |> Map.put_new("dialogue_events", [])
    |> Map.put_new("dependencies", [])
    |> Map.put_new("conflicts", [])
    |> Map.put_new("production_profile_override", %{})
  end
end
