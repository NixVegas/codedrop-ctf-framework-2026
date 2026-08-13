defmodule CtfServer.LocalityTest do
  use ExUnit.Case
  alias CtfServer.Locality

  setup do
    prev = Application.get_env(:ctf_server, :local_networks, [])
    Application.put_env(:ctf_server, :local_networks, ["10.7.0.0/16", "10.8.0.0/16"])
    on_exit(fn -> Application.put_env(:ctf_server, :local_networks, prev) end)
  end

  test "matches an IP inside a local CIDR" do
    assert Locality.local?({10, 7, 3, 42})
    assert Locality.local?({10, 8, 255, 1})
  end

  test "rejects an IP outside every local CIDR" do
    refute Locality.local?({1, 2, 3, 4})
    refute Locality.local?({10, 9, 0, 1})
  end

  test "trusts the loopback proxy when it arrives as an IPv4-mapped IPv6 peer" do
    # Phoenix on a dual-stack `::` listener reports nginx's 127.0.0.1 peer as
    # ::ffff:127.0.0.1 (an 8-tuple). The X-Real-IP header must still be honored,
    # otherwise every client behind the proxy reads as remote.
    mapped_loopback = {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}

    assert Locality.client_ip(%{
             x_headers: [{"x-real-ip", "10.7.0.129"}],
             peer_data: %{address: mapped_loopback}
           }) == {10, 7, 0, 129}
  end

  test "local? matches an IPv4-mapped IPv6 address against v4 CIDRs" do
    # ::ffff:10.7.0.129 must count as local just like 10.7.0.129.
    assert Locality.local?({0, 0, 0, 0, 0, 0xFFFF, 0x0A07, 0x0081})
  end

  test "matches an IPv6 address inside a v6 CIDR and rejects one outside it" do
    Application.put_env(:ctf_server, :local_networks, ["2001:db8::/32"])

    assert Locality.local?({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})
    refute Locality.local?({0x2001, 0x0DB9, 0, 0, 0, 0, 0, 1})
  end

  test "/0 matches everything and /32 requires an exact v4 match" do
    Application.put_env(:ctf_server, :local_networks, ["0.0.0.0/0"])
    assert Locality.local?({1, 2, 3, 4})
    assert Locality.local?({255, 255, 255, 255})

    Application.put_env(:ctf_server, :local_networks, ["10.0.0.1/32"])
    assert Locality.local?({10, 0, 0, 1})
    refute Locality.local?({10, 0, 0, 2})
  end

  test "a v4 IP against a v6-only CIDR list returns false, not a crash" do
    Application.put_env(:ctf_server, :local_networks, ["fe80::/10"])
    refute Locality.local?({10, 0, 0, 1})
  end

  test "a malformed non-string entry in :local_networks is dropped, not a crash" do
    Application.put_env(:ctf_server, :local_networks, [nil, :bad, "10.0.0.0/8"])
    assert Locality.local?({10, 1, 2, 3})
    refute Locality.local?({192, 168, 0, 1})
  end

  test "a negative or too-large prefix CIDR is dropped, not treated as match-everything" do
    Application.put_env(:ctf_server, :local_networks, ["10.0.0.0/-1", "10.0.0.0/33"])
    refute Locality.local?({1, 2, 3, 4})
    refute Locality.local?({10, 0, 0, 1})
  end

  test "client_ip/1 trusts x-real-ip from a loopback peer" do
    conn = %Plug.Conn{remote_ip: {127, 0, 0, 1}, req_headers: [{"x-real-ip", "10.7.0.5"}]}
    assert Locality.client_ip(conn) == {10, 7, 0, 5}
  end

  test "client_ip/1 falls back to the loopback peer when x-real-ip is absent" do
    conn = %Plug.Conn{remote_ip: {127, 0, 0, 1}, req_headers: []}
    assert Locality.client_ip(conn) == {127, 0, 0, 1}
  end

  test "client_ip/1 ignores a spoofed x-forwarded-for header (anti-spoof)" do
    conn = %Plug.Conn{
      remote_ip: {127, 0, 0, 1},
      req_headers: [{"x-forwarded-for", "10.7.0.1"}]
    }

    assert Locality.client_ip(conn) == {127, 0, 0, 1}
  end

  test "client_ip/1 ignores x-real-ip on a direct (non-loopback) connection (anti-spoof)" do
    conn = %Plug.Conn{
      remote_ip: {203, 0, 113, 9},
      req_headers: [{"x-real-ip", "10.7.0.5"}]
    }

    assert Locality.client_ip(conn) == {203, 0, 113, 9}
  end

  test "client_ip/1 handles connect_info with x_headers and peer_data, trusting x-real-ip" do
    connect_info = %{
      x_headers: [{"x-real-ip", "10.7.0.5"}],
      peer_data: %{address: {127, 0, 0, 1}}
    }

    assert Locality.client_ip(connect_info) == {10, 7, 0, 5}
  end

  test "client_ip/1 handles connect_info with only peer_data" do
    connect_info = %{peer_data: %{address: {203, 0, 113, 5}}}
    assert Locality.client_ip(connect_info) == {203, 0, 113, 5}
  end

  test "client_ip/1 returns nil for an unrecognized shape" do
    assert Locality.client_ip(%{some: :other, shape: :entirely}) == nil
  end

  test "local? + client_ip integration: trusted x-real-ip from loopback is local" do
    Application.put_env(:ctf_server, :local_networks, ["10.7.0.0/16"])

    conn = %Plug.Conn{remote_ip: {127, 0, 0, 1}, req_headers: [{"x-real-ip", "10.7.0.5"}]}
    assert Locality.local?(Locality.client_ip(conn))
  end

  test "local? + client_ip integration: spoofed x-forwarded-for is NOT local (spoof blocked)" do
    Application.put_env(:ctf_server, :local_networks, ["10.7.0.0/16"])

    conn = %Plug.Conn{
      remote_ip: {127, 0, 0, 1},
      req_headers: [{"x-forwarded-for", "10.7.0.5"}]
    }

    refute Locality.local?(Locality.client_ip(conn))
  end
end
