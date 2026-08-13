defmodule CtfServer.TrackTest do
  use ExUnit.Case, async: true

  alias CtfServer.Challenge
  alias CtfServer.Challenges
  alias CtfServer.Track

  describe "title/1" do
    test "gives the player-facing title for a known slug" do
      assert Track.title("basic-nix") == "Basic Nix"
      assert Track.title("nix-ecosystem") == "The Nix Ecosystem"
    end

    test "humanizes an unknown slug rather than crashing" do
      assert Track.title("brand-new-track") == "Brand New Track"
    end
  end

  describe "blurb/1" do
    test "gives the framing line for a known slug" do
      assert is_binary(Track.blurb("erinyes"))
    end

    test "is nil for an unknown slug" do
      refute Track.blurb("brand-new-track")
    end
  end

  describe "order/1" do
    test "puts fundamentals before the harder tracks" do
      assert Track.order("basic-nix") < Track.order("advanced-nix")
      assert Track.order("advanced-nix") < Track.order("erinyes")
    end

    test "sorts unknown slugs after every known track" do
      known = Enum.map(Track.slugs(), &Track.order/1)
      assert Track.order("brand-new-track") > Enum.max(known)
    end
  end

  # Compiled only in the test env (test/support/challenges), so it is not a real
  # track and deliberately has no Track entry.
  @support_groups ["test-no-vm"]

  test "every challenge group in the app has a track entry" do
    groups =
      Challenges.get_available_challenges()
      |> Enum.map(&Challenge.group/1)
      |> Enum.uniq()
      |> Kernel.--(@support_groups)

    missing = groups -- Track.slugs()

    assert missing == [],
           "these challenge groups have no CtfServer.Track entry, so they render " <>
             "with a humanized slug and sort to the end: #{inspect(missing)}"
  end
end
