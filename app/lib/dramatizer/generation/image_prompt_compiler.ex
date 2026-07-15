defmodule Dramatizer.Generation.ImagePromptCompiler do
  @moduledoc "Compiles controlled provider prompts without changing Chinese authority data."

  alias Dramatizer.CanonicalJSON

  @version "image-prompt-compiler-v1"
  @task_types [:reference_image, :shot_keyframe, :image_edit]

  def compile(task_type, chinese_authority, opts \\ [])
      when task_type in @task_types and is_map(chinese_authority) do
    links = %{
      "revision_ids" => Keyword.get(opts, :revision_ids, []),
      "reference_asset_ids" => Keyword.get(opts, :reference_asset_ids, []),
      "template_version" => "image-prompt-v1"
    }

    user_instruction = Keyword.get(opts, :user_instruction, "")
    authority_json = CanonicalJSON.encode(chinese_authority)

    provider_prompt =
      [
        "任务=#{task_type}",
        "以下为中文权威数据；保持人物、场景、道具、必须项和禁止项，不得反向改写权威数据。",
        authority_json,
        "精确依赖=#{CanonicalJSON.encode(links)}",
        if(user_instruction == "", do: nil, else: "本次用户指令=#{user_instruction}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    {:ok,
     %{
       task_type: task_type,
       chinese_authority: chinese_authority,
       chinese_authority_hash: CanonicalJSON.hash(chinese_authority),
       provider_prompt: provider_prompt,
       provider_prompt_hash: CanonicalJSON.hash_bytes(provider_prompt),
       links: links,
       compiler_version: @version
     }}
  end
end
