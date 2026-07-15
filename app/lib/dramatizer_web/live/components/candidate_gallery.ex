defmodule DramatizerWeb.Live.Components.CandidateGallery do
  use DramatizerWeb, :html

  attr :candidates, :list, default: []
  attr :upstream_path, :string, default: nil

  def candidate_gallery(assigns) do
    groups =
      assigns.candidates
      |> Enum.group_by(& &1.slot_key)
      |> Enum.sort_by(&elem(&1, 0))

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <section class="candidate-review" aria-labelledby="candidate-title">
      <div class="section-heading compact">
        <div>
          <p class="eyebrow">CANDIDATE REVIEW</p>
          <h2 id="candidate-title">候选图审阅</h2>
          <p>按对象槽位或 Shot 分组比较；技术检查只负责阻断，最终主图必须由你明确选择。</p>
        </div>
        <span class="count-pill">{length(@candidates)}</span>
      </div>

      <div :if={@candidates == []} class="empty-panel compact">
        <p>还没有候选图。系统不会替你默认选择。</p>
      </div>

      <section
        :for={{slot_key, candidates} <- @groups}
        class="candidate-group"
        data-candidate-group={slot_key}
      >
        <div class="candidate-group__heading">
          <div>
            <span class="eyebrow">{group_kind(slot_key)}</span>
            <h3>{slot_label(slot_key)}</h3>
          </div>
          <span class="count-pill">{length(candidates)} 个候选</span>
        </div>
        <div class="candidate-grid">
          <article :for={candidate <- candidates} class="candidate-card">
            <div class="candidate-media">
              <img
                :if={candidate.image_url}
                src={candidate.image_url}
                alt={"候选图 " <> candidate.asset.id}
              />
              <div :if={!candidate.image_url} class="media-placeholder">9:16</div>
              <span :if={candidate.selected} class="selected-flag">当前主图</span>
              <span class={["candidate-mode", candidate.formal && "is-formal"]}>
                {if candidate.formal, do: "正式", else: "探索"}
              </span>
            </div>
            <div class="candidate-card__body">
              <div class="candidate-meta">
                <span>候选 #{candidate.index + 1}</span><span>{candidate.spec_kind}</span>
              </div>
              <p class="candidate-summary">{candidate.summary}</p>
              <div
                :if={candidate.reference_urls != []}
                class="reference-thumbs"
                aria-label="精确参考图"
              >
                <img
                  :for={url <- candidate.reference_urls}
                  src={url}
                  alt="生成规格引用的参考图"
                />
              </div>
              <div class="qc-row">
                <.state_badge state={qc_state(candidate.technical)} label="技术" /><.state_badge
                  state={qc_state(candidate.semantic)}
                  label="语义"
                />
              </div>
              <details :if={candidate.semantic_evidence != %{}} class="qc-details" open>
                <summary>逐维证据</summary>
                <dl>
                  <div :for={{dimension, evidence} <- candidate.semantic_evidence}>
                    <dt>{dimension_label(dimension)}</dt>
                    <dd>
                      <span class={"evidence-#{evidence["status"]}"}>
                        {evidence_label(evidence["status"])}
                      </span>
                      · {evidence["reason"]}<small :if={evidence["advice"]}>{evidence["advice"]}</small>
                    </dd>
                  </div>
                </dl>
              </details>
              <div class="candidate-trace">
                <span>{attempt_label(List.first(candidate.attempts))}</span><strong :if={
                  is_integer(candidate.cost_micros)
                }>${:erlang.float_to_binary(candidate.cost_micros / 1_000_000, decimals: 6)}</strong><strong :if={
                  is_nil(candidate.cost_micros)
                }>实际费用未返回</strong>
              </div>

              <div class="candidate-actions">
                <button
                  type="button"
                  name="candidate"
                  class="btn btn-primary w-full"
                  phx-click="select-candidate"
                  phx-value-asset-id={candidate.asset.id}
                  phx-value-spec-id={candidate.spec_id}
                  phx-value-slot-key={candidate.slot_key}
                  data-candidate-index={candidate.index}
                  disabled={candidate.technical != :pass || candidate.selected}
                >
                  {if candidate.selected, do: "当前主图", else: "选择为主图"}
                </button>
                <button
                  type="button"
                  class="btn btn-soft w-full"
                  phx-click="regenerate-candidate"
                  phx-value-spec-id={candidate.spec_id}
                >
                  再次生成
                </button>
                <.link :if={@upstream_path} navigate={@upstream_path} class="btn btn-ghost w-full">
                  返回上游修改
                </.link>
              </div>

              <form
                id={"edit-candidate-#{candidate.asset.id}"}
                phx-submit="edit-candidate"
                phx-value-asset-id={candidate.asset.id}
                phx-value-spec-id={candidate.spec_id}
                phx-value-slot-key={candidate.slot_key}
                class="candidate-edit"
              >
                <label>
                  <span>编辑指令</span>
                  <input
                    type="text"
                    name="edit[instruction]"
                    placeholder="例如：加强雨水反光，保持人物身份"
                    required
                  />
                </label>
                <button type="submit" class="btn btn-ghost w-full">基于此图编辑</button>
              </form>

              <details class="acceptance-note">
                <summary>带验收备注选择</summary>
                <form
                  phx-submit="select-candidate-with-note"
                  phx-value-asset-id={candidate.asset.id}
                  phx-value-spec-id={candidate.spec_id}
                  phx-value-slot-key={candidate.slot_key}
                >
                  <textarea
                    name="selection[note]"
                    rows="2"
                    placeholder="记录为何接受语义告警或选择此候选"
                  ></textarea>
                  <button
                    type="submit"
                    class="btn btn-ghost w-full"
                    disabled={candidate.technical != :pass}
                  >
                    保存备注并选择
                  </button>
                </form>
              </details>
            </div>
          </article>
        </div>
      </section>
    </section>
    """
  end

  defp group_kind("reference:" <> _rest), do: "REFERENCE SLOT"
  defp group_kind("shot:" <> _rest), do: "SHOT"
  defp group_kind(_rest), do: "CANDIDATE GROUP"
  defp slot_label("reference:" <> value), do: value |> String.split("/") |> Enum.join(" · ")
  defp slot_label("shot:" <> value), do: "镜头 #{value}"
  defp slot_label(value), do: value

  defp attempt_label(nil), do: "尚未提交 Attempt"

  defp attempt_label(attempt),
    do: "#{attempt.adapter} · #{attempt.model} · 尝试 #{attempt.attempt_number}"

  defp dimension_label("identity_variant"), do: "角色身份与 Variant"
  defp dimension_label("wardrobe"), do: "服装与状态"
  defp dimension_label("location"), do: "场景一致性"
  defp dimension_label("lighting"), do: "光线"
  defp dimension_label("key_props"), do: "关键道具"
  defp dimension_label("must_forbid"), do: "禁止项"
  defp dimension_label("composition"), do: "构图"
  defp dimension_label("camera"), do: "摄影"
  defp dimension_label("action"), do: "动作"
  defp dimension_label("expression"), do: "表情"
  defp dimension_label("style"), do: "风格"
  defp dimension_label("artifacts"), do: "生成瑕疵"
  defp dimension_label(value), do: value

  defp evidence_label("pass"), do: "通过"
  defp evidence_label("fail"), do: "不通过"
  defp evidence_label("warning"), do: "警告"
  defp evidence_label(value), do: value || "未评估"

  defp qc_state(:pass), do: :ready

  defp qc_state(value) when value in [:warning, :inconclusive, :evaluator_failed],
    do: :waiting_user

  defp qc_state(:fail), do: :failed
  defp qc_state(_), do: :empty
end
