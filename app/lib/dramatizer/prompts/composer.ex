defmodule Dramatizer.Prompts.Composer do
  @moduledoc "Composes an immutable CorePrompt with exactly one task Appendix revision."

  alias Dramatizer.CanonicalJSON
  alias Dramatizer.Projects.PromptAppendix
  alias Dramatizer.Prompts.Catalog

  @separator "\n\n--- 用户可编辑补充 ---\n\n"

  def compose(task_type, %PromptAppendix{} = appendix, assigns) do
    if appendix.task_type == Atom.to_string(task_type) do
      core = Catalog.fetch!(task_type)
      rendered_core = render(core, assigns)
      content = rendered_core <> @separator <> appendix.body

      {:ok,
       %{
         task_type: task_type,
         core_version: Catalog.version(),
         core_hash: CanonicalJSON.hash_bytes(core),
         appendix_revision_id: appendix.id,
         appendix_revision: appendix.revision,
         appendix_hash: appendix.body_hash,
         content: content,
         content_hash: CanonicalJSON.hash_bytes(content)
       }}
    else
      {:error, :appendix_task_mismatch}
    end
  end

  defp render(template, assigns) do
    Enum.reduce(assigns, template, fn {key, value}, content ->
      String.replace(content, "{{#{key}}}", to_string(value))
    end)
  end
end
