defmodule Mix.Tasks.Ctf.BuildNixpkgsWordlist do
  @shortdoc "Extracts a nixpkgs-derived word list into priv/nixpkgs_words.txt"
  @moduledoc """
  Reads a nixpkgs checkout and writes the clean single-word package names from
  `pkgs/by-name/*/*/` into `priv/nixpkgs_words.txt`.

  A word qualifies when it matches `^[a-z]{4,9}$`. The output is deduped and
  sorted. The file is checked in, so production needs no nixpkgs checkout.

      mix ctf.build_nixpkgs_wordlist [PATH]

  PATH defaults to $NIXPKGS. This is a one-shot generator — the output is
  checked in, so it only needs running when nixpkgs has moved enough to matter.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    path =
      case args do
        [p | _] ->
          p

        [] ->
          System.get_env("NIXPKGS") ||
            Mix.raise("pass a nixpkgs checkout path, or set $NIXPKGS")
      end

    by_name = Path.join([path, "pkgs", "by-name"])

    unless File.dir?(by_name) do
      Mix.raise("no pkgs/by-name under #{path}; pass a nixpkgs checkout path")
    end

    words =
      Path.wildcard(Path.join(by_name, "*/*"))
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&Path.basename/1)
      |> Enum.filter(&Regex.match?(~r/^[a-z]{4,9}$/, &1))
      |> Enum.uniq()
      |> Enum.sort()

    out = Path.join([File.cwd!(), "priv", "nixpkgs_words.txt"])
    File.write!(out, Enum.join(words, "\n") <> "\n")
    Mix.shell().info("wrote #{length(words)} words to #{out}")
  end
end
