defmodule CtfServerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :ctf_server

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  # `secure: true` in prod (set via :secure_cookies in prod.exs) stops the
  # browser sending the session cookie over plaintext HTTP, so it can't be
  # sniffed on the wire (CWE-614). Off by default for dev/test over HTTP.
  @session_options [
    store: :cookie,
    key: "_ctf_server_key",
    signing_salt: "K3xWRD71",
    same_site: "Lax",
    secure: Application.compile_env(:ctf_server, :secure_cookies, false)
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:x_headers, :peer_data, session: @session_options]],
    longpoll: [connect_info: [:x_headers, :peer_data, session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :ctf_server,
    gzip: false,
    only: CtfServerWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :ctf_server
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug CtfServerWeb.Router
end
