defmodule CtfServer.Track do
  @moduledoc """
  Player-facing display metadata for a challenge track.

  A challenge carries its track as a kebab-case slug in `group/0` (`"basic-nix"`),
  and that slug is what routes, attempts, and audit events store — it stays the
  identifier everywhere. This module is the one place that maps a slug to the
  things a *player* should see instead: a title, a one-line framing, and where
  the track sits in the intended progression.

  Ordering matters as much as the titles. Sorting tracks by slug puts
  `advanced-nix` above `basic-nix` and buries `recon` in the middle, so the
  dashboard used to greet a new team with the hard track first. `order/1` gives
  the deliberate teaching order instead: fundamentals, then building, then
  operating, then the adversarial tracks, then erinyes.

  Unknown slugs degrade rather than crash: `title/1` humanizes the slug and
  `order/1` sorts it to the end. A challenge added in a brand-new group still
  renders — it just looks unstyled until it is listed here (which
  `CtfServer.TrackTest` will fail on, so it does not go unnoticed).
  """

  # {slug, title, blurb} — in the order players should meet them.
  #
  # Blurbs are deliberately plain and factual for now: they describe the skill,
  # not the story. They are the natural home for the event's narrative framing,
  # so expect the lore pass to rewrite this column and leave the rest alone.
  @tracks [
    {"basic-nix", "Basic Nix", "Read and evaluate your first Nix expressions."},
    {"advanced-nix", "Advanced Nix", "The REPL, traces, derivations, and overrides."},
    {"deployment-with-nix", "Deployment with Nix",
     "Dev shells, flakes, and builds you can hand to someone else."},
    {"nixos-admin", "NixOS Administration",
     "Push a configuration to a machine you have no shell on."},
    {"secure-nixos", "Securing NixOS",
     "Declarative services, groups, and firewalls — and where they leak."},
    {"nix-ecosystem", "The Nix Ecosystem",
     "Read the source, ask the community, land a real contribution."},
    {"hacking-with-nix", "Hacking with Nix", "The store remembers what you thought you deleted."},
    {"capture-the-poll", "Capture the Poll",
     "A flag that only ever crosses the wire between two other machines."},
    {"recon", "Recon", "The arena is an input. Everything in this room is in the closure."},
    {"social-engineering", "Social Engineering",
     "People are inputs too, and people are not reproducible."},
    {"erinyes", "Erinyes",
     "Five rungs of privilege escalation. The last one is for those with full agency."}
  ]

  @titles Map.new(@tracks, fn {slug, title, _} -> {slug, title} end)
  @blurbs Map.new(@tracks, fn {slug, _, blurb} -> {slug, blurb} end)
  @order @tracks |> Enum.with_index() |> Map.new(fn {{slug, _, _}, i} -> {slug, i} end)
  @slugs Enum.map(@tracks, fn {slug, _, _} -> slug end)

  @doc "Every known track slug, in progression order."
  @spec slugs() :: [String.t()]
  def slugs, do: @slugs

  @doc """
  The player-facing title for a track slug.

  Falls back to a humanized form of the slug so an unlisted group still renders.
  """
  @spec title(String.t()) :: String.t()
  def title(slug) when is_binary(slug), do: Map.get(@titles, slug) || humanize(slug)

  @doc """
  The one-line framing shown under a track's title, or `nil` if the track has
  none (including any unlisted group).
  """
  @spec blurb(String.t()) :: String.t() | nil
  def blurb(slug) when is_binary(slug), do: Map.get(@blurbs, slug)

  @doc """
  A track's position in the intended progression, for sorting.

  Unlisted tracks sort after every known one.
  """
  @spec order(String.t()) :: non_neg_integer()
  def order(slug) when is_binary(slug), do: Map.get(@order, slug, length(@tracks))

  defp humanize(slug) do
    slug
    |> String.split("-")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
