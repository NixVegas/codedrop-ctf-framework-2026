defmodule CtfServerWeb.CompetitionLeaderboardTest do
  use CtfServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CtfServer.AccountsFixtures
  alias CtfServer.Competition

  test "before start, a public visitor sees the holding message, not the table", %{conn: conn} do
    {:ok, _} =
      Competition.update(Competition.get(), %{starts_at: ~U[2999-01-01 00:00:00Z], ends_at: nil})

    {:ok, _lv, html} = live(conn, ~p"/leaderboard")
    assert html =~ "has not started"
    refute html =~ "team-rankings-table"
  end

  test "during, the table renders", %{conn: conn} do
    {:ok, _} = Competition.update(Competition.get(), %{starts_at: nil, ends_at: nil})
    {:ok, _lv, html} = live(conn, ~p"/leaderboard")
    assert html =~ "team-rankings-table"
  end

  test "before start, an admin still sees the table", %{conn: conn} do
    admin = admin_team_fixture()

    {:ok, _} =
      Competition.update(Competition.get(), %{starts_at: ~U[2999-01-01 00:00:00Z], ends_at: nil})

    {:ok, _lv, html} = conn |> log_in_team(admin) |> live(~p"/leaderboard")
    assert html =~ "team-rankings-table"
    refute html =~ "has not started"
  end
end
