defmodule Dramatizer.RuntimeConfigTest do
  use ExUnit.Case, async: true

  test "the web endpoint is restricted to IPv4 loopback" do
    endpoint = Application.fetch_env!(:dramatizer, DramatizerWeb.Endpoint)
    assert get_in(endpoint, [:http, :ip]) == {127, 0, 0, 1}
  end

  test "database, provider, and local media settings are explicit" do
    repo = Application.fetch_env!(:dramatizer, Dramatizer.Repo)

    assert is_binary(repo[:url])
    assert Application.fetch_env!(:dramatizer, :provider_mode) in [:fake, :openai]

    asset_store_root = Application.fetch_env!(:dramatizer, :asset_store_root)
    assert Path.type(asset_store_root) == :absolute
    assert is_binary(Application.fetch_env!(:dramatizer, :media_worker_python))
    assert is_binary(Application.fetch_env!(:dramatizer, :ffmpeg_path))
    assert is_binary(Application.fetch_env!(:dramatizer, :ffprobe_path))
  end
end
