defmodule Dramatizer.Repo do
  use Ecto.Repo,
    otp_app: :dramatizer,
    adapter: Ecto.Adapters.Postgres
end
