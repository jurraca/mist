defmodule Mist.Repo do
  use Ecto.Repo,
    otp_app: :mist,
    adapter: Ecto.Adapters.SQLite3
end
