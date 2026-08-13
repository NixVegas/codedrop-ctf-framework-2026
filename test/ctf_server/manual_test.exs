defmodule CtfServer.ManualTest do
  use ExUnit.Case, async: true

  alias CtfServer.Manual

  test "surfaces a page for every solution guide that exists at compile time" do
    on_disk =
      [__DIR__, "..", "..", "lib", "ctf_server", "challenges", "*.solution.md"]
      |> Path.join()
      |> Path.wildcard()
      |> length()

    assert length(Manual.pages()) == on_disk
    assert on_disk > 0, "no solution guides found — did the glob path change?"
  end

  test "each page carries a slug and a title" do
    for page <- Manual.pages() do
      assert is_binary(page.slug) and page.slug != ""
      assert is_binary(page.title) and page.title != ""
    end
  end

  test "slugs are unique, so routing is unambiguous" do
    slugs = Manual.pages() |> Enum.map(& &1.slug)
    assert length(slugs) == length(Enum.uniq(slugs))
  end

  test "a challenge-backed page is enriched with its group, level, and points" do
    page = Manual.get_page("basic-nix-1")

    assert page.title == "Your First Nix Expression"
    assert page.group == "basic-nix"
    assert page.level == 1
    assert page.points == 100
  end

  test "get_page renders the guide's markdown to HTML" do
    page = Manual.get_page("basic-nix-1")

    assert page.html =~ "<h1"
    assert page.html =~ "Do not ship to players"
  end

  test "renders GFM tables and code blocks the guides use" do
    # basic-nix/1 has a fenced code block; capture-the-poll/1 uses tables.
    assert Manual.get_page("basic-nix-1").html =~ "<pre"

    tabled = Enum.find(Manual.pages(), fn p -> Manual.get_page(p.slug).html =~ "<table" end)
    assert tabled, "expected at least one guide to render a markdown table"
  end

  test "get_page is nil for an unknown slug" do
    assert Manual.get_page("does-not-exist") == nil
  end

  test "groups pages by track, with challenge tracks under their group name" do
    groups = Manual.pages_by_group() |> Enum.map(&elem(&1, 0))

    assert "basic-nix" in groups
    assert "nix-ecosystem" in groups
    refute nil in groups, "a missing group must fall back to a label, never nil"
  end
end
