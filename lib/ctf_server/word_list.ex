defmodule CtfServer.WordList do
  @moduledoc """
  Invite-code word pool: nixpkgs package names. The file ships under `priv/` and
  loads once at compile time.
  """

  @external_resource Path.join(:code.priv_dir(:ctf_server), "nixpkgs_words.txt")

  @words :ctf_server
         |> :code.priv_dir()
         |> Path.join("nixpkgs_words.txt")
         |> File.read!()
         |> String.split("\n", trim: true)
         |> Enum.map(&String.downcase/1)
         |> Enum.uniq()

  @doc "The deduped word pool."
  @spec words() :: [String.t()]
  def words, do: @words

  @doc "A hyphen-joined code of `word_count` uniformly random words."
  @spec code(pos_integer()) :: String.t()
  def code(word_count) when word_count > 0 do
    pool = @words
    size = length(pool)

    1..word_count
    |> Enum.map(fn _ -> Enum.at(pool, rand_index(size)) end)
    |> Enum.join("-")
  end

  # Crypto-strong uniform index in 0..size-1 via rejection sampling on 4 bytes.
  defp rand_index(size) do
    <<n::unsigned-32>> = :crypto.strong_rand_bytes(4)
    limit = div(0x100000000, size) * size
    if n < limit, do: rem(n, size), else: rand_index(size)
  end
end
