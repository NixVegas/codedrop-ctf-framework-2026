defmodule CtfServer.Repo do
  use Ecto.Repo,
    otp_app: :ctf_server,
    adapter: Ecto.Adapters.Postgres
end
