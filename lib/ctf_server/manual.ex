defmodule CtfServer.Manual do
  @moduledoc """
  The staff manual: the per-challenge solution guides, browsable in-app.

  ## Why the content is embedded at compile time

  The guides live next to their challenges as `lib/**/*.solution.md`. A
  `mix release` (which is how this ships — see `nix/package.nix`) bundles only
  compiled beam and `priv/`, **not** the `lib/` source tree, so reading those
  files at runtime would work in dev and 404 in production.

  Instead every `*.solution.md` is read at compile time into `@raw` and baked
  into the beam. `@external_resource` on each path makes the module recompile
  when an existing guide changes, so `mix` in dev stays in sync.

  > **Dev caveat:** the resource list is fixed at compile time, so *adding a new*
  > guide file (as opposed to editing one) won't trigger a recompile on its own —
  > run `mix compile --force` once after creating it. Production is never
  > affected: a `mix release` always builds from clean, picking up every file.

  The rendered HTML is **not** precomputed: markdown is cheap to render and the
  manual is admin-only and low-traffic, so `render/1` runs Earmark on demand
  rather than carrying a second copy of every guide in the beam.

  ## Adding non-solution guides later

  This currently sources pages from the solution files only. To add a standing
  guide (say a runbook), give it an `@external_resource`, read it into `@raw`
  under its own key, and teach `meta_for/1` how to title and slug it. Everything
  downstream — the sidebar, routing, rendering — is keyed off `pages/0` and
  needs no change.
  """

  alias CtfServer.Challenge

  @solutions_glob Path.join([__DIR__, "challenges", "*.solution.md"])

  # Sorted so the compiled-in order is deterministic across builds.
  @solution_paths @solutions_glob |> Path.wildcard() |> Enum.sort()

  for path <- @solution_paths do
    @external_resource path
  end

  # base ("BasicNix1") => raw markdown. Baked into the beam; present in a release.
  @raw (for path <- @solution_paths, into: %{} do
          {Path.basename(path, ".solution.md"), File.read!(path)}
        end)

  @doc """
  Every manual page, enriched with challenge metadata and sorted for display.

  Each entry: `%{slug, title, group, level, points}`. The raw markdown is not
  included here (see `get_page/1`) so the sidebar stays cheap to build.
  """
  def pages do
    @raw
    |> Map.keys()
    |> Enum.map(&meta_for/1)
    |> Enum.sort_by(&{&1.group || "~", &1.level || 0, &1.title})
  end

  @doc """
  Manual pages grouped by track, in display order, as `[{group, [page]}]`.

  The group is the challenge `group` (e.g. `"basic-nix"`); pages with no
  associated challenge fall under `"guides"`.
  """
  def pages_by_group do
    pages()
    |> Enum.group_by(& &1.group)
    |> Enum.map(fn {group, pages} -> {group || "guides", pages} end)
    |> Enum.sort_by(fn {group, _pages} -> group end)
  end

  @doc """
  A single page by slug, with its markdown rendered to HTML, or `nil`.

  Returns `%{slug, title, group, level, points, html}`.
  """
  def get_page(slug) when is_binary(slug) do
    case Enum.find(pages(), &(&1.slug == slug)) do
      nil -> nil
      meta -> Map.put(meta, :html, render(@raw |> Map.fetch!(base_for(meta))))
    end
  end

  @doc "Renders one guide's markdown to HTML."
  def render(markdown) when is_binary(markdown) do
    Earmark.as_html!(markdown)
  end

  # Look up challenge metadata for a solution file's base name. A file whose
  # base doesn't match a challenge still gets a page — it just falls back to a
  # title derived from the file name and lands under "guides".
  #
  # The file and its challenge are matched on the downcased last module segment,
  # not by reconstructing a module name from the filename: the two can differ in
  # case (`SecureNixos1.solution.md` sits beside `CtfServer.Challenges.SecureNixOS1`),
  # so a literal `Module.concat` would miss it.
  defp meta_for(base) do
    case Map.get(challenge_index(), String.downcase(base)) do
      nil ->
        %{
          base: base,
          slug: base |> Macro.underscore() |> String.replace("_", "-"),
          title: base,
          group: nil,
          level: nil,
          points: nil
        }

      challenge ->
        %{
          base: base,
          slug: "#{Challenge.group(challenge)}-#{Challenge.level(challenge)}",
          title: Challenge.name(challenge),
          group: Challenge.group(challenge),
          level: Challenge.level(challenge),
          points: Challenge.max_score(challenge)
        }
    end
  end

  # Registered challenges keyed by their downcased module-tail, so a solution
  # file's base name lines up with its challenge regardless of casing.
  defp challenge_index do
    for challenge <- CtfServer.Challenges.get_available_challenges(), into: %{} do
      key = challenge.__struct__ |> Module.split() |> List.last() |> String.downcase()
      {key, challenge}
    end
  end

  defp base_for(%{base: base}), do: base
end
