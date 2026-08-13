defmodule CtfServerWeb.AdminManualLiveTest do
  use CtfServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CtfServer.AccountsFixtures

  setup %{conn: conn} do
    %{conn: log_in_team(conn, admin_team_fixture()), team: team_fixture()}
  end

  describe "access control" do
    test "redirects non-admin teams", %{team: team} do
      conn = build_conn() |> log_in_team(team) |> get(~p"/admin/manual")
      assert redirected_to(conn) == ~p"/dashboard"
    end

    test "redirects logged-out visitors" do
      conn = get(build_conn(), ~p"/admin/manual")
      assert redirected_to(conn) == ~p"/teams/log_in"
    end
  end

  describe "index" do
    test "lists every track as a sidebar group", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/manual")

      assert html =~ "Manual"
      assert html =~ "basic-nix"
      assert html =~ "nix-ecosystem"
      # a page's title links to its slug
      assert html =~ ~p"/admin/manual/basic-nix-1"
    end
  end

  describe "a guide" do
    test "renders the selected solution's content", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/manual/basic-nix-1")

      assert html =~ "Do not ship to players"
      assert html =~ "Your First Nix Expression"
    end

    test "navigating between guides swaps the content", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/manual/basic-nix-1")

      html =
        lv |> element(~s{a[href="#{~p"/admin/manual/capture-the-poll-1"}"]}) |> render_click()

      assert html =~ "Capture the Poll"
    end

    test "flashes on an unknown guide instead of crashing", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/manual/nonsense")
      assert html =~ "No such guide"
    end
  end
end
