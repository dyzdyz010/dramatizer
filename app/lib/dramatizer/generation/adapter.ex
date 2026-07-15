defmodule Dramatizer.Generation.Adapter do
  @moduledoc "Stateless provider adapter contract."

  alias Dramatizer.Generation.{Attempt, ProviderRequestSnapshot}

  @callback submit(ProviderRequestSnapshot.t(), Attempt.t()) ::
              {:ok, map()} | {:error, atom(), map()}
end
