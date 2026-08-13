defmodule CtfServerWeb.TeamDashboardLiveTest do
  use CtfServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CtfServer.AccountsFixtures

  describe "Dashboard page" do
    @tag :skip
    test "renders dashboard page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_team(team_fixture())
        |> live(~p"/dashboard")

      assert html =~ "Challenges"
    end

    test "renders a paused attempt without crashing", %{conn: conn} do
      team = team_fixture()

      {:ok, _attempt} =
        CtfServer.Challenges.create_challenge_attempt(%{
          group: "basic-nix",
          level: 1,
          status: :paused,
          team_id: team.id
        })

      {:ok, _lv, html} =
        conn
        |> log_in_team(team)
        |> live(~p"/dashboard")

      assert html =~ "Paused"
    end

    test "redirects if team is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/dashboard")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/teams/log_in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end
end
