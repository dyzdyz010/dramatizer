defmodule Dramatizer.Directing.CanonicalJSON do
  @moduledoc "Compiler-scoped canonical JSON facade."

  defdelegate encode(value), to: Dramatizer.CanonicalJSON
  defdelegate hash(value), to: Dramatizer.CanonicalJSON
end
