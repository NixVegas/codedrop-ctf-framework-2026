defmodule CtfServerWeb.Plugs.RateLimitAuth do
  @moduledoc """
  Rate-limits an auth POST by client IP. When the IP exceeds the limit for the
  configured `bucket` (see `CtfServer.RateLimiter`), the request is halted with
  a flash and a redirect back to the log-in page, and a `Retry-After` header.

  This guards `POST /teams/log_in` against password brute-forcing and the
  Argon2 CPU cost each attempt incurs (CWE-307). The post-registration and
  post-password-update logins carry an `_action` param and are let through:
  they follow a flow that already ran its own gating.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  alias CtfServer.Locality
  alias CtfServer.RateLimiter

  def init(opts), do: Keyword.fetch!(opts, :bucket)

  def call(%Plug.Conn{params: %{"_action" => _}} = conn, _bucket), do: conn

  def call(conn, bucket) do
    case RateLimiter.check(bucket, client_id(conn)) do
      {:allow, _count} ->
        conn

      {:deny, retry_after_ms} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(ceil_seconds(retry_after_ms)))
        |> put_flash(:error, "Too many attempts. Please wait a moment and try again.")
        |> redirect(to: "/teams/log_in")
        |> halt()
    end
  end

  # The client IP as a string, or "unknown" when it can't be resolved (which
  # buckets all such requests together rather than exempting them).
  defp client_id(conn) do
    case Locality.client_ip(conn) do
      ip when is_tuple(ip) -> ip |> :inet.ntoa() |> to_string()
      _ -> "unknown"
    end
  end

  defp ceil_seconds(ms), do: div(ms + 999, 1000)
end
