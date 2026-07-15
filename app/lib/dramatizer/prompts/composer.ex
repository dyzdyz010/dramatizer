defmodule Dramatizer.Prompts.Composer do
  @moduledoc "Composes an immutable CorePrompt with exactly one task Appendix revision."

  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Projects.PromptAppendix
  alias Dramatizer.Prompts.Catalog

  @separator "\n\n--- 用户可编辑补充 ---\n\n"

  def compose(task_type, %PromptAppendix{} = appendix, assigns) do
    if appendix.task_type == Atom.to_string(task_type) do
      build(task_type, assigns, appendix)
    else
      {:error, :appendix_task_mismatch}
    end
  end

  def compose(task_type, nil, assigns), do: build(task_type, assigns, nil)

  defp build(task_type, assigns, appendix) do
    core = Catalog.fetch!(task_type)
    rendered_core = render(core, assigns)
    content = if appendix, do: rendered_core <> @separator <> appendix.body, else: rendered_core

    {:ok,
     %{
       task_type: task_type,
       core_version: Catalog.version(),
       core_hash: CanonicalJSON.hash_bytes(core),
       appendix_revision_id: appendix && appendix.id,
       appendix_revision: appendix && appendix.revision,
       appendix_hash: appendix && appendix.body_hash,
       content: content,
       content_hash: CanonicalJSON.hash_bytes(content)
     }}
  end

  defp render(template, assigns) do
    Enum.reduce(assigns, template, fn {key, value}, content ->
      String.replace(content, "{{#{key}}}", to_string(value))
    end)
  end
end
