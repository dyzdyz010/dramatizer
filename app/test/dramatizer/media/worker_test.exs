defmodule Dramatizer.Media.WorkerTest do
  use ExUnit.Case, async: true

  alias Dramatizer.Media.Worker

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  test "versioned worker probes a valid image" do
    path =
      Path.join(System.tmp_dir!(), "dramatizer-probe-#{System.unique_integer([:positive])}.png")

    File.write!(path, @png)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, result} = Worker.run(:probe_image, %{"path" => path})
    assert result["width"] == 1
    assert result["height"] == 1
    assert result["format"] == "PNG"
  end

  test "worker reports stable errors instead of emitting a traceback" do
    assert {:error, %{code: "file_not_found"}} =
             Worker.run(:probe_image, %{"path" => "missing-image.png"})

    assert {:error, %{code: "unknown_command"}} = Worker.run(:not_a_command, %{})
  end

  test "worker protocol remains valid for Unicode outside the Windows code page" do
    assert {:error, %{code: "file_not_found", message: message}} =
             Worker.run(:probe_image, %{"path" => "missing-😀.png"})

    assert message =~ "😀"
  end

  test "worker returns a stable timeout instead of leaving a caller blocked" do
    runner = fn _executable, _args, _options ->
      Process.sleep(200)
      {"late", 0}
    end

    assert {:error, %{code: "worker_timeout"}} =
             Worker.run(:probe_image, %{"path" => "unused"},
               timeout: 10,
               command_runner: runner
             )
  end
end
