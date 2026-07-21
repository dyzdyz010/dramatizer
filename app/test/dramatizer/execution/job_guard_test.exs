defmodule Dramatizer.Execution.JobGuardTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Dramatizer.Execution.JobGuard

  test "converts raises, throws, and exits into sanitized lifecycle failures" do
    secret = "Bearer sk-should-never-escape"

    log =
      capture_log(fn ->
        assert {:error, :worker_exception, details} =
                 JobGuard.protect(fn -> raise secret end)

        assert details == %{
                 "exception_module" => "RuntimeError",
                 "failure_kind" => "exception"
               }

        assert {:error, :worker_throw, %{"failure_kind" => "throw"}} =
                 JobGuard.protect(fn -> throw({:private, secret}) end)

        assert {:error, :worker_exit, %{"failure_kind" => "exit"}} =
                 JobGuard.protect(fn -> exit({:private, secret}) end)
      end)

    refute log =~ secret
  end

  test "returns successful values without changing their shape" do
    assert {:ok, {:error, :domain_failure, %{}}} =
             JobGuard.protect(fn -> {:error, :domain_failure, %{}} end)
  end
end
