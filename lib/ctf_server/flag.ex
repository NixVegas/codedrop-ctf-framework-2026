defmodule CtfServer.Flag do
  @moduledoc """
  Keyed per-team flag derivation.

  Per-team flags are an HMAC-SHA256 over a per-challenge label and the team id,
  keyed with a subkey derived from the Phoenix `secret_key_base`. Because the key
  is a server secret that teams never have, knowing a team id (or reading this
  open-source derivation) is not enough to compute a flag.

  `seed/2` is a drop-in for `:crypto.hash(:sha256, "\#{label}:\#{team.id}")`: it
  returns the same 32 raw bytes, so existing `Base.encode16/binary_part` pipes in
  the challenges are unchanged.
  """

  alias CtfServer.Accounts.Team

  # Domain separation: the flag key is derived from `secret_key_base` rather than
  # being equal to it (which also signs cookies and tokens). Bump the version
  # segment to deliberately rotate every per-team flag at once.
  @context "ctf-server/flag-derivation/v1"

  @doc """
  32 raw bytes of keyed seed for challenge `label` and `team`.

  Drop-in replacement for `:crypto.hash(:sha256, "\#{label}:\#{team.id}")`.
  """
  @spec seed(String.t(), Team.t()) :: binary()
  def seed(label, %Team{} = team) do
    :crypto.mac(:hmac, :sha256, key(), "#{label}:#{team.id}")
  end

  @doc "Lowercase-hex form of `seed/2` (64 chars; callers truncate as needed)."
  @spec seed_hex(String.t(), Team.t()) :: String.t()
  def seed_hex(label, team), do: seed(label, team) |> Base.encode16(case: :lower)

  # Derive a dedicated flag key from secret_key_base so flag derivation is
  # domain-separated from the raw signing secret.
  defp key, do: :crypto.mac(:hmac, :sha256, secret_key_base(), @context)

  defp secret_key_base do
    Application.get_env(:ctf_server, CtfServerWeb.Endpoint)[:secret_key_base] ||
      raise "secret_key_base is not configured; cannot derive per-team flags"
  end
end
