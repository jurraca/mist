defmodule Mist.Repo do
  use Ecto.Repo,
    otp_app: :mist,
    adapter: Ecto.Adapters.Postgres
end
