defmodule Dramatizer.Generation.Adapters.ProxyOptions do
  @moduledoc """
  Derives Req connect options from the standard HTTPS_PROXY/HTTP_PROXY
  environment variables.

  The BEAM does not honor these variables automatically, so workstations that
  can only reach the provider through a local proxy would otherwise fail with
  transport-level `provider_unavailable` errors while proxy-aware tools work.
  Callers can still override `connect_options` explicitly; NO_PROXY is not
  interpreted because the only remote hosts are provider APIs.
  """

  def options do
    case proxy_endpoint() do
      nil -> []
      {host, port} -> [connect_options: [proxy: {:http, host, port, []}]]
    end
  end

  defp proxy_endpoint do
    value =
      System.get_env("HTTPS_PROXY") || System.get_env("https_proxy") ||
        System.get_env("HTTP_PROXY") || System.get_env("http_proxy")

    with value when is_binary(value) and value != "" <- value,
         %URI{host: host, port: port} when is_binary(host) and is_integer(port) <-
           URI.parse(value) do
      {host, port}
    else
      _ -> nil
    end
  end
end
