defmodule CtfServerWeb.AdminCompetitionLiveTest do
  use CtfServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CtfServer.AccountsFixtures
  alias CtfServer.Competition

  test "non-admin is redirected", %{conn: conn} do
    conn = log_in_team(conn, team_fixture())
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/admin/competition")
  end

  test "admin sets the window", %{conn: conn} do
    conn = log_in_team(conn, admin_team_fixture())
    {:ok, lv, _html} = live(conn, ~p"/admin/competition")

    lv
    |> form("#competition_form",
      competition: %{starts_at: "2026-08-06T11:00", ends_at: "2026-08-09T20:00"}
    )
    |> render_submit()

    c = Competition.get()
    assert c.starts_at == ~U[2026-08-06 11:00:00.000000Z]
    assert c.ends_at == ~U[2026-08-09 20:00:00.000000Z]
  end

  test "admin clears a bound", %{conn: conn} do
    admin = admin_team_fixture()

    {:ok, _} =
      Competition.update(Competition.get(), %{starts_at: ~U[2026-08-06 11:00:00Z], ends_at: nil})

    conn = log_in_team(conn, admin)
    {:ok, lv, _html} = live(conn, ~p"/admin/competition")

    lv |> form("#competition_form", competition: %{starts_at: "", ends_at: ""}) |> render_submit()
    assert Competition.get().starts_at == nil
  end
end
