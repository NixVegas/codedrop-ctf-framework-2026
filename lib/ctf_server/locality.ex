defmodule CtfServer.Locality do
  @moduledoc """
  Decides whether a client is on the local network. The client IP comes from
  the proxy-set `X-Real-IP` header when the connection arrives from a trusted
  loopback proxy (nginx runs on loopback in front of Phoenix and sets
  `X-Real-IP` to `$remote_addr`, overwriting any client-supplied value),
  falling back to the socket peer IP otherwise. `local?/1` matches the IP
  against `:local_networks` CIDRs.
  """

  import Bitwise

  @doc "True if `ip` is inside any configured local CIDR."
  @spec local?(:inet.ip_address()) :: boolean()
  def local?(ip) when is_tuple(ip) do
    ip = unmap(ip)
    Enum.any?(local_networks(), fn {net, prefix} -> in_cidr?(ip, net, prefix) end)
  end

  def local?(_), do: false

  defp local_networks do
    Application.get_env(:ctf_server, :local_networks, [])
    |> Enum.flat_map(fn cidr ->
      case parse_cidr(cidr) do
        {:ok, net, prefix} -> [{net, prefix}]
        :error -> []
      end
    end)
  end

  @doc "Parses `\"10.0.0.0/8\"` into `{:ok, ip, prefix_len}`."
  def parse_cidr(cidr) when is_binary(cidr) do
    with [addr, len] <- String.split(cidr, "/"),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(addr)),
         {len, ""} <- Integer.parse(len),
         true <- valid_prefix?(ip, len) do
      {:ok, ip, len}
    else
      _ -> :error
    end
  end

  def parse_cidr(_), do: :error

  defp valid_prefix?(ip, len) when tuple_size(ip) == 4, do: len in 0..32
  defp valid_prefix?(ip, len) when tuple_size(ip) == 8, do: len in 0..128
  defp valid_prefix?(_, _), do: false

  defp in_cidr?(ip, net, prefix) when tuple_size(ip) == tuple_size(net) do
    bits = tuple_size(ip) * if tuple_size(ip) == 4, do: 8, else: 16
    to_int(ip) >>> (bits - prefix) == to_int(net) >>> (bits - prefix)
  end

  defp in_cidr?(_, _, _), do: false

  defp to_int(tuple) do
    width = if tuple_size(tuple) == 4, do: 8, else: 16

    tuple
    |> Tuple.to_list()
    |> Enum.reduce(0, fn part, acc -> (acc <<< width) + part end)
  end

  @doc """
  Extracts the client IP from a `Plug.Conn` or LiveView `connect_info`.

  Behind a trusted loopback proxy (nginx), the real client IP comes from the
  proxy-set `X-Real-IP` header (nginx sets it to `$remote_addr` and overwrites
  any client-supplied value). On a direct connection the socket peer IS the
  client, and any header is ignored (a direct client could forge it). When no
  trustworthy real IP is available, falls back to the peer IP, which behind the
  proxy is loopback and therefore not local -> the client is treated as remote
  (fail closed).
  """
  def client_ip(%Plug.Conn{} = conn), do: ip_from_proxy(conn.req_headers, conn.remote_ip)

  def client_ip(%{x_headers: headers, peer_data: %{address: peer}}),
    do: ip_from_proxy(headers, peer)

  def client_ip(%{peer_data: %{address: peer}}), do: unmap(peer)
  def client_ip(_), do: nil

  defp ip_from_proxy(headers, peer_ip) do
    peer = unmap(peer_ip)
    if trusted_proxy?(peer), do: real_ip(headers) || peer, else: peer
  end

  defp real_ip(headers) do
    with value when is_binary(value) <-
           Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == "x-real-ip", do: v end),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(String.trim(value))) do
      unmap(ip)
    else
      _ -> nil
    end
  end

  defp trusted_proxy?({127, _, _, _}), do: true
  defp trusted_proxy?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp trusted_proxy?(_), do: false

  # An IPv4-mapped IPv6 address (::ffff:a.b.c.d) collapses to its IPv4 tuple;
  # anything else is returned unchanged. Phoenix on a dual-stack `::` listener
  # reports an IPv4 peer (e.g. nginx on 127.0.0.1) as ::ffff:127.0.0.1, so this
  # must run before the trusted-proxy and CIDR checks or every client, including
  # the loopback proxy, reads as untrusted/remote.
  defp unmap({0, 0, 0, 0, 0, 0xFFFF, g7, g8}),
    do: {g7 >>> 8, g7 &&& 0xFF, g8 >>> 8, g8 &&& 0xFF}

  defp unmap(ip), do: ip
end
