defmodule CtfServer.CompetitionGatingTest do
  use CtfServer.DataCase, async: false

  import CtfServer.AccountsFixtures
  alias CtfServer.{Accounts, Challenges, Competition}

  defp close_window do
    {:ok, _} =
      Competition.update(Competition.get(), %{
        starts_at: ~U[2020-01-01 00:00:00Z],
        ends_at: ~U[2020-01-02 00:00:00Z]
      })
  end

  defp reg_attrs do
    %{
      "name" => "T#{System.unique_integer([:positive])}",
      "email" => "t#{System.unique_integer([:positive])}@example.com",
      "password" => "hello world!"
    }
  end

  test "start_challenge_attempt is blocked when closed for non-admins" do
    # team_fixture/1 registers via the now-gated Accounts.register_team/2, so
    # it must run before the window closes; only the start call needs to see
    # it closed.
    team = team_fixture()
    close_window()

    assert {:error, :competition_closed} =
             Challenges.start_challenge_attempt(team, "nix-ecosystem", 1)
  end

  test "admins bypass the closed window when starting a challenge" do
    admin = admin_team_fixture()
    close_window()
    # Not :competition_closed, proceeds into the normal start path.
    assert Challenges.start_challenge_attempt(admin, "nix-ecosystem", 1) !=
             {:error, :competition_closed}
  end

  test "register_team is blocked when registration is closed" do
    close_window()
    assert {:error, :registration_closed} = Accounts.register_team(reg_attrs())
  end

  test "open window still registers and starts" do
    # default seeded window is open
    assert {:ok, _team} = Accounts.register_team(reg_attrs())
  end
end
