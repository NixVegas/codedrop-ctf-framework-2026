defmodule CtfServerWeb.ChallengeLiveNoVmTest do
  use CtfServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CtfServer.AccountsFixtures
  import CtfServer.ChallengesFixtures

  setup %{conn: conn} do
    team = team_fixture()
    %{conn: log_in_team(conn, team), team: team}
  end

  test "a started no-VM challenge shows the flag form but no SSH/key details", %{
    conn: conn,
    team: team
  } do
    challenge_attempt_fixture(%{
      team_id: team.id,
      group: "nix-ecosystem",
      level: 1,
      status: :started
    })

    {:ok, _lv, html} = live(conn, ~p"/challenge/nix-ecosystem/1")

    refute html =~ "ssh -i ctf.key"
    refute html =~ "Your private key"
    assert html =~ "no VM to log into"
    assert html =~ "Capture"
  end

  test "a started VM challenge still shows SSH connection details", %{conn: conn, team: team} do
    challenge_attempt_fixture(%{
      team_id: team.id,
      group: "basic-nix",
      level: 1,
      status: :started,
      port: 2222
    })

    {:ok, _lv, html} = live(conn, ~p"/challenge/basic-nix/1")

    assert html =~ "ssh -i ctf.key"
  end
end
