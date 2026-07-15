defmodule DramatizerWeb.Live.Components.AnalysisReview do
  use DramatizerWeb, :html

  attr :snapshot, :map, default: nil

  def analysis_review(assigns) do
    assigns =
      assigns
      |> assign(:groups, groups(assigns.snapshot))
      |> assign(:candidate_count, count_items(assigns.snapshot, "episode_candidates"))

    ~H"""
    <section class="analysis-review" data-analysis-review aria-labelledby="analysis-review-title">
      <div class="section-heading compact">
        <div>
          <p class="eyebrow">ANALYSIS PROPOSAL</p>
          <h3 id="analysis-review-title">分析审阅</h3>
          <p>AI 提取结果仍是提案；选择分集并确认后才会成为制作权威。</p>
        </div>
        <span :if={@snapshot} class="count-pill">{@candidate_count} 个分集候选</span>
      </div>

      <div :if={!@snapshot} class="empty-panel compact">导入原著后将自动在这里生成整本分析。</div>

      <div :if={@snapshot} class="analysis-groups">
        <article :for={group <- @groups} class="analysis-group" data-analysis-group={group.key}>
          <div class="analysis-group__heading">
            <div>
              <span class="eyebrow">{group.code}</span>
              <h4>{group.label}</h4>
            </div>
            <span class="count-pill">{length(group.items)}</span>
          </div>

          <div :if={group.items == []} class="empty-panel compact">本组没有发现需要审阅的条目。</div>

          <div class="analysis-card-grid">
            <article :for={item <- group.items} class="analysis-item-card">
              <div class="analysis-item-card__title">
                <div>
                  <span class="eyebrow">{item["kind"]} · {item["id"]}</span>
                  <h5>{item["name"] || item["data"]["title"] || "未命名条目"}</h5>
                </div>
                <span class={semantic_class(item["source_semantics"])}>
                  {semantic_label(item["source_semantics"])}
                </span>
              </div>
              <p>{item_summary(item)}</p>
              <div :if={(item["references"] || []) != []} class="reference-chips">
                <span :for={reference <- item["references"]}>{reference}</span>
              </div>
              <details :if={(item["locators"] || []) != []} class="source-inspector">
                <summary>查看原文定位 · {length(item["locators"])} 处</summary>
                <ul>
                  <li :for={locator <- item["locators"]}>{locator_label(locator)}</li>
                </ul>
              </details>
            </article>
          </div>
        </article>
      </div>
    </section>
    """
  end

  defp groups(nil), do: []

  defp groups(snapshot) do
    [
      group(snapshot, "people_relations", "A1", "人物与关系"),
      group(snapshot, "places_props_world", "A2", "地点、道具与世界"),
      group(snapshot, "events_timeline", "A3", "事件与时间线"),
      group(snapshot, "entity_merge", "A4", "实体归并建议"),
      group(snapshot, "episode_candidates", "A5", "分集候选"),
      group(snapshot, "conflict_check", "A6", "冲突与待决项")
    ]
  end

  defp group(snapshot, key, code, label),
    do: %{key: key, code: code, label: label, items: items(snapshot, key)}

  defp items(snapshot, key),
    do: get_in(snapshot.node_results, [key, "output", "items"]) || []

  defp count_items(nil, _key), do: 0
  defp count_items(snapshot, key), do: length(items(snapshot, key))

  defp item_summary(item) do
    data = item["data"] || %{}
    data["summary"] || data["description"] || data["conflict"] || summarize_data(data)
  end

  defp summarize_data(data) when map_size(data) == 0, do: "已完成结构化提取，等待人工审阅。"

  defp summarize_data(data) do
    data
    |> Enum.reject(fn {_key, value} -> is_map(value) or is_list(value) end)
    |> Enum.map_join(" · ", fn {key, value} -> "#{key}: #{value}" end)
    |> case do
      "" -> "包含结构化详情，可在后续制作表单中继续编辑。"
      summary -> summary
    end
  end

  defp semantic_label("source_grounded"), do: "原文明确"
  defp semantic_label("inferred"), do: "合理推断"
  defp semantic_label("creative"), do: "创作补充"
  defp semantic_label(_value), do: "待核对"

  defp semantic_class(value), do: ["semantic-chip", "semantic-#{value || "unknown"}"]

  defp locator_label(locator) do
    cond do
      locator["page"] -> "第 #{locator["page"]} 页"
      locator["start_offset"] -> "字符 #{locator["start_offset"]}–#{locator["end_offset"]}"
      true -> "已记录来源定位"
    end
  end
end
