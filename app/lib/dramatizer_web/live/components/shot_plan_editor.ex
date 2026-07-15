defmodule DramatizerWeb.Live.Components.ShotPlanEditor do
  use DramatizerWeb, :html

  alias DramatizerWeb.Forms.ShotPlanDraftForm

  attr :draft, :map, required: true

  def shot_plan_editor(assigns) do
    payload =
      assigns.draft.payload
      |> ShotPlanDraftForm.from_payload()
      |> Map.put_new("scenes", [])
      |> Map.put_new("shots", [])
      |> Map.put_new("continuity", %{})

    assigns = assign(assigns, :payload, payload)

    ~H"""
    <article class="authority-editor shot-plan-editor" data-shot-plan-editor>
      <div class="section-heading compact">
        <div>
          <p class="eyebrow">DIRECTING AUTHORITY · DRAFT</p>
          <h3>导演方案与镜头节奏</h3>
          <p>每个 Shot 明确呈现目标、摄影、调度、声音、连续性、时长和生成约束。</p>
        </div>
        <span class={status_class(@draft.status)}>{status_label(@draft.status)}</span>
      </div>

      <div class="continuity-strip">
        <div><span>Scene</span><strong>{length(@payload["scenes"])}</strong></div>
        <div><span>Shot</span><strong>{length(@payload["shots"])}</strong></div>
        <div><span>建议时长</span><strong>{preferred_duration(@payload["shots"])}s</strong></div>
        <div><span>连续性轨道</span><strong>{@payload["continuity"]["track"] || "未指定"}</strong></div>
      </div>

      <form
        :if={@draft.status == :editing}
        id={"shot-plan-draft-#{@draft.id}"}
        phx-submit="save-shot-plan-draft"
        phx-value-id={@draft.id}
        class="authority-form"
      >
        <section class="form-section plan-strategy">
          <div class="form-section__heading">
            <div>
              <span class="eyebrow">PLAN STRATEGY</span>
              <h4>全局声音与连续性</h4>
            </div>
            <button
              type="button"
              class="btn btn-soft"
              phx-click="add-shot-item"
              phx-value-id={@draft.id}
              phx-value-collection="scenes"
            >
              ＋ 新增 Scene
            </button>
          </div>
          <div class="field-grid three-up">
            <.text_field
              name="shot_plan[sound_strategy]"
              label="全局声音策略"
              value={@payload["sound_strategy"]}
            />
            <.text_field
              name="shot_plan[continuity][track]"
              label="连续性轨道"
              value={@payload["continuity"]["track"]}
            />
            <.text_field
              name="shot_plan[continuity][notes]"
              label="全局连续性说明"
              value={@payload["continuity"]["notes"]}
            />
          </div>
        </section>

        <section
          :for={{scene, scene_index} <- Enum.with_index(@payload["scenes"])}
          class="shot-scene-group"
        >
          <div class="shot-scene-group__heading">
            <div>
              <span class="eyebrow">SCENE {pad(scene_index + 1)} · {scene["id"]}</span>
              <h4>{scene["name"]}</h4>
              <p>{scene["purpose"]}</p>
            </div>
            <div class="scene-heading-actions">
              <button
                type="button"
                class="btn btn-soft"
                phx-click="add-shot-item"
                phx-value-id={@draft.id}
                phx-value-collection="shots"
                phx-value-scene-id={scene["id"]}
              >
                ＋ 新增 Shot
              </button>
              <.item_controls draft_id={@draft.id} collection="scenes" item_id={scene["id"]} />
            </div>
          </div>
          <input type="hidden" name={"shot_plan[scenes][#{scene_index}][id]"} value={scene["id"]} />
          <div class="field-grid two-up">
            <.text_field
              name={"shot_plan[scenes][#{scene_index}][name]"}
              label="Scene 名称"
              value={scene["name"]}
            /><.text_field
              name={"shot_plan[scenes][#{scene_index}][purpose]"}
              label="Scene 目的"
              value={scene["purpose"]}
            />
          </div>

          <article
            :for={
              {shot, shot_index} <- shots_for(@payload["shots"], scene["id"]) |> Enum.with_index()
            }
            class="shot-card"
          >
            <% global_index = global_shot_index(@payload["shots"], shot["id"]) %>
            <div class="shot-card__heading">
              <div>
                <span class="shot-number">SHOT {pad(shot_index + 1)}</span>
                <h5>{shot["presentation_goal"]}</h5>
                <span class="shot-duration">{shot["preferred_duration_ms"]} ms</span>
              </div>
              <.item_controls draft_id={@draft.id} collection="shots" item_id={shot["id"]} />
            </div>
            <input type="hidden" name={"shot_plan[shots][#{global_index}][id]"} value={shot["id"]} />
            <input
              type="hidden"
              name={"shot_plan[shots][#{global_index}][scene_id]"}
              value={scene["id"]}
            />

            <div class="field-grid three-up">
              <.text_field
                name={"shot_plan[shots][#{global_index}][beat_id]"}
                label="Beat ID"
                value={shot["beat_id"]}
              />
              <.text_field
                name={"shot_plan[shots][#{global_index}][story_event_ids]"}
                label="StoryEvent IDs"
                value={shot["story_event_ids"]}
              />
              <.text_field
                name={"shot_plan[shots][#{global_index}][coverage]"}
                label="覆盖角色"
                value={shot["coverage"]}
              />
              <.text_field
                name={"shot_plan[shots][#{global_index}][shot_class]"}
                label="镜头类别"
                value={shot["shot_class"]}
              />
              <.text_field
                name={"shot_plan[shots][#{global_index}][presentation_goal]"}
                label="呈现目标"
                value={shot["presentation_goal"]}
              />
              <.text_field
                name={"shot_plan[shots][#{global_index}][timing_rationale]"}
                label="时长理由"
                value={shot["timing_rationale"]}
              />
            </div>
            <.area_field
              name={"shot_plan[shots][#{global_index}][description]"}
              label="画面动作与变化"
              value={shot["description"]}
            />
            <div class="duration-fields">
              <.number_field
                name={"shot_plan[shots][#{global_index}][minimum_duration_ms]"}
                label="最短 ms"
                value={shot["minimum_duration_ms"]}
              /><span>≤</span>
              <.number_field
                name={"shot_plan[shots][#{global_index}][preferred_duration_ms]"}
                label="建议 ms"
                value={shot["preferred_duration_ms"]}
              /><span>≤</span>
              <.number_field
                name={"shot_plan[shots][#{global_index}][maximum_duration_ms]"}
                label="最长 ms"
                value={shot["maximum_duration_ms"]}
              />
            </div>

            <details open class="director-details">
              <summary>摄影参数</summary>
              <div class="field-grid three-up">
                <.text_field
                  :for={{field, label} <- camera_fields()}
                  name={"shot_plan[shots][#{global_index}][camera][#{field}]"}
                  label={label}
                  value={get_in(shot, ["camera", field])}
                />
              </div>
            </details>
            <details class="director-details">
              <summary>场面调度</summary>
              <div class="field-grid two-up">
                <.text_field
                  name={"shot_plan[shots][#{global_index}][staging][location_ref]"}
                  label="地点引用"
                  value={get_in(shot, ["staging", "location_ref"])}
                /><.text_field
                  name={"shot_plan[shots][#{global_index}][staging][participant_refs]"}
                  label="参与者引用"
                  value={get_in(shot, ["staging", "participant_refs"])}
                /><.text_field
                  name={"shot_plan[shots][#{global_index}][staging][prop_refs]"}
                  label="道具引用"
                  value={get_in(shot, ["staging", "prop_refs"])}
                /><.area_field
                  name={"shot_plan[shots][#{global_index}][staging][blocking_notes]"}
                  label="走位说明"
                  value={get_in(shot, ["staging", "blocking_notes"])}
                />
              </div>
            </details>
            <details class="director-details">
              <summary>声音策略</summary>
              <div class="field-grid three-up">
                <.text_field
                  name={"shot_plan[shots][#{global_index}][audio_strategy][mode]"}
                  label="声音模式"
                  value={get_in(shot, ["audio_strategy", "mode"])}
                /><.text_field
                  name={"shot_plan[shots][#{global_index}][audio_strategy][dialogue_event_ids]"}
                  label="DialogueEvent IDs"
                  value={get_in(shot, ["audio_strategy", "dialogue_event_ids"])}
                /><.text_field
                  name={"shot_plan[shots][#{global_index}][audio_strategy][sound_notes]"}
                  label="声音说明"
                  value={get_in(shot, ["audio_strategy", "sound_notes"])}
                />
              </div>
            </details>
            <details open class="director-details continuity-details">
              <summary>连续性</summary>
              <div class="field-grid two-up">
                <.area_field
                  name={"shot_plan[shots][#{global_index}][continuity][start_state]"}
                  label="开始状态"
                  value={get_in(shot, ["continuity", "start_state"])}
                /><.area_field
                  name={"shot_plan[shots][#{global_index}][continuity][actions]"}
                  label="镜内动作"
                  value={get_in(shot, ["continuity", "actions"])}
                /><.area_field
                  name={"shot_plan[shots][#{global_index}][continuity][end_state]"}
                  label="结束状态"
                  value={get_in(shot, ["continuity", "end_state"])}
                /><.text_field
                  name={"shot_plan[shots][#{global_index}][continuity][relation_to_previous]"}
                  label="与前镜关系"
                  value={get_in(shot, ["continuity", "relation_to_previous"])}
                />
              </div>
            </details>
            <details open class="director-details constraint-details">
              <summary>生成约束</summary>
              <div class="field-grid three-up">
                <.area_field
                  name={"shot_plan[shots][#{global_index}][constraints][must_show]"}
                  label="必须出现"
                  value={get_in(shot, ["constraints", "must_show"])}
                /><.area_field
                  name={"shot_plan[shots][#{global_index}][constraints][must_not_show]"}
                  label="禁止出现"
                  value={get_in(shot, ["constraints", "must_not_show"])}
                /><.area_field
                  name={"shot_plan[shots][#{global_index}][constraints][reference_object_ids]"}
                  label="精确参考对象"
                  value={get_in(shot, ["constraints", "reference_object_ids"])}
                />
              </div>
            </details>
          </article>
        </section>

        <footer class="sticky-form-actions">
          <span>ShotPlan 确认后才允许编译付费生成规格</span>
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
        <div><span>Scene</span><strong>{length(@payload["scenes"])}</strong></div>
        <div><span>Shot</span><strong>{length(@payload["shots"])}</strong></div>
        <div><span>建议总时长</span><strong>{preferred_duration(@payload["shots"])}s</strong></div>
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
      <span>{@label}</span> <input type="number" min="250" name={@name} value={@value} />
    </label>
    """
  end

  attr :draft_id, :string, required: true
  attr :collection, :string, required: true
  attr :item_id, :string, required: true

  defp item_controls(assigns) do
    ~H"""
    <div class="item-controls">
      <button
        type="button"
        aria-label="上移"
        phx-click="move-shot-item"
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
        phx-click="move-shot-item"
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
        phx-click="remove-shot-item"
        phx-value-id={@draft_id}
        phx-value-collection={@collection}
        phx-value-item-id={@item_id}
      >
        ×
      </button>
    </div>
    """
  end

  defp shots_for(shots, scene_id), do: Enum.filter(shots, &(&1["scene_id"] == scene_id))
  defp global_shot_index(shots, shot_id), do: Enum.find_index(shots, &(&1["id"] == shot_id))

  defp preferred_duration(shots),
    do: Float.round(Enum.sum(Enum.map(shots, &(&1["preferred_duration_ms"] || 0))) / 1_000, 1)

  defp camera_fields,
    do: [
      {"shot_size", "景别"},
      {"angle", "角度"},
      {"movement", "运动"},
      {"visual_focus", "视觉焦点"},
      {"composition_notes", "构图说明"},
      {"lens_intent", "镜头意图"}
    ]

  defp status_label(:editing), do: "等待确认"
  defp status_label(:confirmed), do: "已冻结"
  defp status_class(status), do: ["authority-status", "status-#{status}"]
  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
