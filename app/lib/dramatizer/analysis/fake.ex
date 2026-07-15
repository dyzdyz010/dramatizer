defmodule Dramatizer.Analysis.Fake do
  @moduledoc "Deterministic whole-document structured outputs for the offline production path."

  alias Dramatizer.Workflow.NodeRun

  def output(%NodeRun{} = node) do
    source_id = List.first(node.input_snapshot["source_revision_ids"])
    locator = %{"source_revision_id" => source_id, "start_offset" => 0, "end_offset" => 12}

    items =
      case node.node_key do
        "people_relations" ->
          [
            item("person:lead", "person", "林夏", [locator], %{
              "role" => "protagonist",
              "traits" => ["克制", "敏锐"]
            })
          ]

        "places_props_world" ->
          [
            item("location:station", "location", "雨夜车站", [locator], %{
              "time" => "night",
              "weather" => "rain"
            }),
            item("prop:letter", "prop", "匿名信", [locator], %{"state" => "sealed"})
          ]

        "events_timeline" ->
          [
            item("event:letter", "event", "林夏收到匿名信", [locator], %{
              "order" => 1,
              "conflict" => "寄信人身份未知"
            })
          ]

        "entity_merge" ->
          []

        "episode_candidates" ->
          [
            item("episode:001", "episode", "雨夜来信", [locator], %{
              "title" => "雨夜来信",
              "summary" => "林夏在雨夜车站收到一封改变关系走向的匿名信。",
              "dialogue_events" => [
                %{
                  "id" => "D001",
                  "shot_id" => "S001",
                  "text" => "这封信，不该出现在这里。",
                  "start_ms" => 150,
                  "end_ms" => 1_800,
                  "style" => %{"position" => "safe_bottom"}
                },
                %{
                  "id" => "D002",
                  "shot_id" => "S002",
                  "text" => "寄信的人就在附近。",
                  "start_ms" => 2_000,
                  "end_ms" => 3_700,
                  "style" => %{"position" => "safe_bottom"}
                }
              ],
              "scenes" => [%{"id" => "SC001", "name" => "雨夜车站"}]
            })
          ]

        "conflict_check" ->
          []
      end

    %{"items" => items}
  end

  defp item(id, kind, name, locators, data) do
    %{
      "id" => id,
      "kind" => kind,
      "name" => name,
      "source_semantics" => "source_grounded",
      "locators" => locators,
      "references" => [],
      "data" => data
    }
  end
end
