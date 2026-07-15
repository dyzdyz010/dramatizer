defmodule DramatizerWeb.Live.Components.GenerationSpecReview do
  use DramatizerWeb, :html

  attr :revision, :map, default: nil
  attr :specs, :list, default: []

  def generation_spec_review(assigns) do
    assigns = assign(assigns, :compiled_specs, compiled_specs(assigns.revision))

    ~H"""
    <section class="generation-spec-review" aria-labelledby="generation-spec-title">
      <div class="section-heading compact">
        <div>
          <p class="eyebrow">GENERATION SPEC REVIEW</p>
          <h3 id="generation-spec-title">生成规格审阅</h3>
          <p>确认精确输入、媒体规格、约束和候选数量后，再显式触发付费生成。</p>
        </div>
        <span class="count-pill">{length(@compiled_specs)} 个 Shot</span>
      </div>
      <div :if={!@revision} class="empty-panel compact">确认 ShotPlan 后点击“编译生成规格”。</div>
      <div :if={@revision} class="spec-freeze-summary">
        <span>正式规格</span><span>{get_in(@revision.payload, ["frozen_inputs", "compiler_version"])}</span><span>模板 {get_in(@revision.payload, ["frozen_inputs", "template_version"])}</span><span>Revision {String.slice(@revision.content_hash, 0, 12)}</span>
      </div>
      <div class="spec-card-grid">
        <article :for={compiled <- @compiled_specs} class="spec-card">
          <div class="spec-card__heading">
            <div>
              <span class="eyebrow">{compiled["kind"]}</span>
              <h4>{compiled["shot_id"]}</h4>
            </div>
            <span class="formal-chip">正式</span>
          </div>
          <dl>
            <div>
              <dt>呈现目标</dt>
              <dd>{get_in(compiled, ["payload", "presentation_goal"])}</dd>
            </div>
            <div>
              <dt>摄影运动</dt>
              <dd>{get_in(compiled, ["payload", "camera"])}</dd>
            </div>
            <div>
              <dt>媒体规格</dt>
              <dd>
                {get_in(compiled, ["payload", "width"])}×{get_in(compiled, ["payload", "height"])}
              </dd>
            </div>
            <div>
              <dt>候选数</dt>
              <dd>{candidate_count(@specs, compiled["shot_id"])}</dd>
            </div>
          </dl>
          <div class="constraint-chips">
            <span :for={item <- get_in(compiled, ["payload", "must_show"]) || []}>必须 · {item}</span><span
              :for={item <- get_in(compiled, ["payload", "must_not_show"]) || []}
              class="negative"
            >禁止 · {item}</span>
          </div>
          <details>
            <summary>精确输入 Revision</summary>
            <ul>
              <li :for={{key, id} <- get_in(compiled, ["payload", "dependencies"]) || %{}}>
                {key}: {id}
              </li>
            </ul>
          </details>
        </article>
      </div>
    </section>
    """
  end

  defp compiled_specs(nil), do: []
  defp compiled_specs(revision), do: revision.payload["specs"] || []
  defp candidate_count(specs, shot_id), do: Enum.count(specs, &(&1.payload["shot_id"] == shot_id))
end
