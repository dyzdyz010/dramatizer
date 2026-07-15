defmodule DramatizerWeb.Live.Components.CandidateGallery do
  use DramatizerWeb, :html

  attr :candidates, :list, default: []

  def candidate_gallery(assigns) do
    ~H"""
    <section aria-labelledby="candidate-title">
      <div class="section-heading compact">
        <div>
          <p class="eyebrow">CANDIDATES</p>
          <h2 id="candidate-title">候选图对比</h2>
        </div>
        <span class="count-pill">{length(@candidates)}</span>
      </div>

      <div :if={@candidates == []} class="empty-panel compact">
        <p>还没有候选图。系统不会替你默认选择。</p>
      </div>

      <div class="candidate-grid">
        <article :for={candidate <- @candidates} class="candidate-card">
          <div class="candidate-media">
            <img
              :if={candidate.image_url}
              src={candidate.image_url}
              alt={"候选图 " <> candidate.asset.id}
            />
            <div :if={!candidate.image_url} class="media-placeholder">9:16</div>
            <span :if={candidate.selected} class="selected-flag">已选择</span>
          </div>
          <div class="candidate-card__body">
            <div class="candidate-meta">
              <span>候选 #{candidate.index + 1}</span>
              <span>{candidate.spec_kind}</span>
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
              <.state_badge state={qc_state(candidate.technical)} label="技术" />
              <.state_badge state={qc_state(candidate.semantic)} label="语义" />
            </div>
            <details :if={candidate.semantic_evidence != %{}} class="qc-details">
              <summary>逐维证据</summary>
              <dl>
                <div :for={{dimension, evidence} <- candidate.semantic_evidence}>
                  <dt>{dimension}</dt>
                  <dd>{evidence["status"]} · {evidence["reason"]}</dd>
                </div>
              </dl>
            </details>
            <div class="candidate-trace">
              <span>
                {case List.first(candidate.attempts) do
                  nil -> "尚未提交 Attempt"
                  attempt -> "#{attempt.adapter} · #{attempt.model} · 尝试 #{attempt.attempt_number}"
                end}
              </span>
              <strong>
                ${:erlang.float_to_binary(candidate.cost_micros / 1_000_000, decimals: 6)}
              </strong>
            </div>
            <button
              type="button"
              name="candidate"
              class="btn btn-primary w-full"
              phx-click="select-candidate"
              phx-value-asset-id={candidate.asset.id}
              phx-value-spec-id={candidate.spec_id}
              phx-value-slot-key={candidate.slot_key}
              disabled={candidate.technical != :pass || candidate.selected}
            >
              {if candidate.selected, do: "当前选择", else: "选择此候选"}
            </button>
          </div>
        </article>
      </div>
    </section>
    """
  end

  defp qc_state(:pass), do: :ready

  defp qc_state(value) when value in [:warning, :inconclusive, :evaluator_failed],
    do: :waiting_user

  defp qc_state(:fail), do: :failed
  defp qc_state(_), do: :empty
end
