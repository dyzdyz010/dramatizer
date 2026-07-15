defmodule DramatizerWeb.AssetController do
  use DramatizerWeb, :controller

  alias Dramatizer.Assets

  def show(conn, %{"id" => id}) do
    asset = Assets.get_asset!(id)

    conn
    |> put_resp_content_type(asset.mime_type)
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> send_file(200, Assets.absolute_path(asset))
  end
end
