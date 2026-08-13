defmodule CtfServer.ChallengeBannerTest do
  use ExUnit.Case, async: true

  alias CtfServer.ChallengeBanner
  alias CtfServer.Challenges

  defp challenge(group, level) do
    {:ok, challenge} = Challenges.get_challenge_by_group_and_level(group, level)
    challenge
  end

  describe "render/1" do
    test "includes the challenge identity and a submit nudge" do
      banner = ChallengeBanner.render(challenge("basic-nix", 1))

      assert banner =~ "NixCTF"
      assert banner =~ "Your First Nix Expression"
      assert banner =~ "basic-nix / level 1 / 100 pts"
      assert banner =~ "Nix{...}"
    end

    test "lists the egress network-filtering ruleset" do
      banner = ChallengeBanner.render(challenge("basic-nix", 1))

      assert banner =~ "Network filtering (egress from this box)"
      # own /24 and the cache are reachable; the fleet is blocked (module defaults)
      assert banner =~ "reachable  your own /24"
      assert banner =~ "reachable  10.4.2.0/24"
      assert banner =~ "blocked    10.0.0.0/8"
    end

    test "states internet access explicitly, both ways" do
      no_net = ChallengeBanner.render(challenge("basic-nix", 1))
      assert no_net =~ "This challenge has NO public internet access."
      refute no_net =~ "reachable  the public internet"

      with_net = ChallengeBanner.render(challenge("basic-nix", 1), true)
      assert with_net =~ "This challenge HAS public internet access."
      assert with_net =~ "reachable  the public internet"
    end

    test "includes the challenge's task, not its hints" do
      banner = ChallengeBanner.render(challenge("basic-nix", 1))

      # from the "## The task" section
      assert banner =~ "~/challenge.txt"
      assert banner =~ "SHA-256"
      # the hints section (e.g. `nix repl`, builtins links) must not leak in
      refute banner =~ "builtins.hashString"
      refute banner =~ ":?"
    end

    test "renders for every VM challenge" do
      for challenge <- Challenges.get_available_challenges() do
        banner = ChallengeBanner.render(challenge)
        assert banner =~ "NixCTF"
        assert banner =~ CtfServer.Challenge.name(challenge)
        refute banner =~ "## "
      end
    end
  end

  describe "login_files/1" do
    test "injects the banner and a bash_profile that prints it" do
      files = ChallengeBanner.login_files(challenge("basic-nix", 1))
      paths = Enum.map(files, fn {path, _} -> path end)

      assert "/home/ctf/.ctf-banner" in paths
      assert "/home/ctf/.bash_profile" in paths

      {_, banner} = Enum.find(files, fn {path, _} -> path == "/home/ctf/.ctf-banner" end)
      assert banner =~ "Your First Nix Expression"

      {_, profile} = Enum.find(files, fn {path, _} -> path == "/home/ctf/.bash_profile" end)
      assert profile =~ ~s(cat "$HOME/.ctf-banner")
    end
  end
end
