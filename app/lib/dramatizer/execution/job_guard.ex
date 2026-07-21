defmodule Dramatizer.Execution.JobGuard do
  @moduledoc "Converts unexpected worker control flow into sanitized lifecycle failures."

  require Logger

  def protect(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    exception ->
      module = exception.__struct__ |> Module.split() |> Enum.join(".")
      Logger.error("worker execution raised", failure_kind: "exception", exception_module: module)

      {:error, :worker_exception, %{"failure_kind" => "exception", "exception_module" => module}}
  catch
    :throw, _private_value ->
      Logger.error("worker execution threw", failure_kind: "throw")
      {:error, :worker_throw, %{"failure_kind" => "throw"}}

    :exit, _private_reason ->
      Logger.error("worker execution exited", failure_kind: "exit")
      {:error, :worker_exit, %{"failure_kind" => "exit"}}
  end
end
