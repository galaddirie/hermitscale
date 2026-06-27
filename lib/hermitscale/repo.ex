defmodule Hermitscale.Repo do
  use Ecto.Repo,
    otp_app: :hermitscale,
    adapter: Ecto.Adapters.Postgres
end
