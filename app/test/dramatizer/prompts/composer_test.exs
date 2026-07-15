defmodule Dramatizer.Prompts.ComposerTest do
  use Dramatizer.DataCase, async: true

  alias Dramatizer.Projects
  alias Dramatizer.Prompts.{Catalog, Composer}

  test "core prompt precedes only the matching task appendix and hashes every part" do
    assert {:ok, project} = Projects.create_project(%{name: "提示词测试"})

    assert {:ok, people_appendix} =
             Projects.create_prompt_appendix(project, :people_relations, "只补充人物规则。")

    assert {:ok, event_appendix} =
             Projects.create_prompt_appendix(project, :events_timeline, "只补充事件规则。")

    assert {:ok, composed} =
             Composer.compose(:people_relations, people_appendix, %{input_json: ~s({"text":"示例"})})

    core_first_line = Catalog.fetch!(:people_relations) |> String.split("\n") |> hd()
    assert String.starts_with?(composed.content, core_first_line)
    assert composed.content =~ ~s({"text":"示例"})
    refute composed.content =~ "{{input_json}}"
    assert composed.content =~ "只补充人物规则。"
    refute composed.content =~ "只补充事件规则。"
    assert composed.core_version == "v1"
    assert byte_size(composed.core_hash) == 64
    assert byte_size(composed.appendix_hash) == 64
    assert byte_size(composed.content_hash) == 64

    assert {:error, :appendix_task_mismatch} =
             Composer.compose(:people_relations, event_appendix, %{input_json: "{}"})
  end
end
