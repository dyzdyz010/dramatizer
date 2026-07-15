defmodule DramatizerWeb.PageController do
  use DramatizerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
