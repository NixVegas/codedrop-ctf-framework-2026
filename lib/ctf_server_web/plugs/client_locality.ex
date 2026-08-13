defmodule CtfServerWeb.Plugs.ClientLocality do
  @moduledoc """
  Stores whether the request's client IP is local in the session, for the
  registration dead render. The authoritative check re-runs in the LiveView from
  `connect_info`.
  """
  import Plug.Conn
  alias CtfServer.Locality

  def init(opts), do: opts

  def call(conn, _opts) do
    local? = Locality.local?(Locality.client_ip(conn))
    put_session(conn, :client_local, local?)
  end
end
