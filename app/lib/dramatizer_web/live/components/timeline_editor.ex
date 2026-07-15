defmodule DramatizerWeb.Live.Components.TimelineEditor do
  use DramatizerWeb, :html

  attr :timeline, :map, default: nil
  attr :clips, :list, default: []
  attr :subtitles, :list, default: []
  attr :renders, :list, default: []

  def timeline_editor(assigns) do
    ~H"""
    <section aria-labelledby="timeline-title">
      <div class="section-heading compact">
        <div>
          <p class="eyebrow">CUT & CAPTIONS</p>
          <h2 id="timeline-title">时间线与字幕</h2>
        </div>
        <span class="count-pill">{length(@clips)} 镜头</span>
      </div>

      <div :if={is_nil(@timeline)} class="empty-panel compact">
        <p>确认 Narrative、视觉方案和 ShotPlan，并完成镜头选择后创建时间线。</p>
        <button type="button" class="btn btn-primary" phx-click="create-timeline">
          从已确认输入创建
        </button>
      </div>

      <div :if={@timeline} class="timeline-board">
        <div class="clip-strip" role="list" aria-label="镜头时间线">
          <article :for={clip <- @clips} class="clip-card" role="listitem">
            <span class="clip-position">{clip.position}</span>
            <strong>{clip.shot_id}</strong>
            <span>{clip.duration_ms} ms</span>
            <span>{motion_label(clip.motion)}</span>
            <span :if={clip.placeholder} class="warning-chip">缺图占位</span>
            <div class="clip-actions">
              <button
                type="button"
                phx-click="move-clip"
                phx-value-id={clip.id}
                phx-value-position={max(1, clip.position - 1)}
                aria-label={"将 #{clip.shot_id} 左移"}
              >
                ←
              </button>
              <button
                type="button"
                phx-click="move-clip"
                phx-value-id={clip.id}
                phx-value-position={clip.position + 1}
                aria-label={"将 #{clip.shot_id} 右移"}
              >
                →
              </button>
            </div>
          </article>
        </div>

        <div class="subtitle-list">
          <.form
            :for={cue <- @subtitles}
            for={to_form(%{}, as: :cue)}
            id={"subtitle-#{cue.id}"}
            phx-submit="update-subtitle"
            phx-value-id={cue.id}
            class="subtitle-row"
          >
            <label for={"subtitle-text-#{cue.id}"} class="subtitle-field">
              <span>字幕 {cue.position}</span>
              <input
                id={"subtitle-text-#{cue.id}"}
                type="text"
                name="cue[text]"
                value={cue.text}
                class="input w-full"
              />
            </label>
            <input type="hidden" name="cue[start_ms]" value={cue.start_ms} />
            <input type="hidden" name="cue[end_ms]" value={cue.end_ms} />
            <button class="btn btn-ghost" type="submit">保存</button>
          </.form>
        </div>

        <div class="timeline-actions" data-human-gate>
          <button type="button" class="btn btn-soft" phx-click="preview-timeline">生成预览</button>
          <button type="button" class="btn btn-primary" phx-click="freeze-timeline">
            冻结并正式导出
          </button>
        </div>

        <div :if={@renders != []} class="render-list">
          <article :for={render <- @renders} class="trace-row">
            <div>
              <strong>{if render.render_mode == :formal, do: "正式成片", else: "预览"}</strong>
              <p>{render.width}×{render.height} · {render.duration_ms} ms</p>
            </div>
            <.state_badge state={render_state(render.status)} />
            <div :if={render.status == :rendered} class="render-downloads">
              <a
                :if={render.output_asset_id}
                href={"/media/#{render.output_asset_id}"}
                download={"dramatizer-#{render.render_mode}.mp4"}
                class="btn btn-ghost"
              >
                MP4
              </a>
              <a
                :if={render.srt_asset_id}
                href={"/media/#{render.srt_asset_id}"}
                download={"dramatizer-#{render.render_mode}.srt"}
                class="btn btn-ghost"
              >
                SRT
              </a>
            </div>
          </article>
        </div>
      </div>
    </section>
    """
  end

  defp motion_label(:static), do: "静态"
  defp motion_label(:push_in), do: "推进"
  defp motion_label(:pull_out), do: "拉远"
  defp motion_label(:pan_left), do: "左移"
  defp motion_label(:pan_right), do: "右移"
  defp motion_label(:pan_up), do: "上移"
  defp motion_label(:pan_down), do: "下移"

  defp render_state(:rendered), do: :ready
  defp render_state(:failed), do: :failed
  defp render_state(:rendering), do: :loading
  defp render_state(_), do: :waiting_user
end
