defmodule Dramatizer.Media.Worker do
  @moduledoc "Client for the versioned, one-request Python media protocol."

  @protocol_version 1

  def run(command, payload, opts \\ []) when is_atom(command) and is_map(payload) do
    python = Application.fetch_env!(:dramatizer, :media_worker_python)
    script = Application.app_dir(:dramatizer, "priv/media_worker/worker.py")

    request =
      %{"protocol_version" => @protocol_version, "payload" => payload}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    timeout =
      Keyword.get(
        opts,
        :timeout,
        Application.get_env(:dramatizer, :media_worker_timeout, 300_000)
      )

    task =
      Task.async(fn ->
        try do
          {:ok,
           runner.(python, [script, Atom.to_string(command), request], stderr_to_stdout: true)}
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {output, 0}}} ->
        decode_response(output)

      {:ok, {:ok, {output, status}}} ->
        {:error, %{code: "worker_exit", message: String.trim(output), status: status}}

      {:ok, {:error, message}} ->
        {:error, %{code: "worker_unavailable", message: message}}

      nil ->
        {:error, %{code: "worker_timeout", message: "media worker exceeded #{timeout} ms"}}
    end
  rescue
    error -> {:error, %{code: "worker_unavailable", message: Exception.message(error)}}
  end

  defp decode_response(output) do
    with line when is_binary(line) <- output |> String.split("\n", trim: true) |> List.last(),
         {:ok, response} <- Jason.decode(line),
         true <- response["protocol_version"] == @protocol_version do
      case response do
        %{"ok" => true, "result" => result} -> {:ok, result}
        %{"ok" => false, "error" => error} -> {:error, normalize_error(error)}
      end
    else
      _ -> {:error, %{code: "invalid_worker_response", message: String.trim(output)}}
    end
  end

  defp normalize_error(error) do
    %{
      code: Map.get(error, "code", "worker_error"),
      message: Map.get(error, "message", "media worker failed")
    }
  end
end
