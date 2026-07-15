defmodule Dramatizer.Changes.Impact do
  @moduledoc "Read-only exact dependency impact preview."

  defstruct [
    :project_id,
    :old_revision_id,
    :new_revision_id,
    :graph_epoch,
    :diff,
    targets: []
  ]
end
