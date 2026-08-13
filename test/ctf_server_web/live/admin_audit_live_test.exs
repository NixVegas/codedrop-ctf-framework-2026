defmodule CtfServerWeb.AdminAuditLiveTest do
  use CtfServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CtfServer.AccountsFixtures

  alias CtfServer.Audit

  setup %{conn: conn} do
    admin = admin_team_fixture()
    team = team_fixture()
    %{conn: log_in_team(conn, admin), admin: admin, team: team}
  end

  describe "access control" do
    test "redirects non-admin teams", %{team: team} do
      conn = build_conn() |> log_in_team(team) |> get(~p"/admin/audit")

      assert redirected_to(conn) == ~p"/dashboard"
    end
  end

  describe "listing" do
    test "shows events newest first with principal links", %{conn: conn, team: team} do
      {:ok, _lv, html} = live(conn, ~p"/admin/audit")

      # registration fixtures recorded account.create events
      assert html =~ "account.create"
      assert html =~ team.email
      assert html =~ ~p"/admin/teams/#{team.id}"
    end

    test "paginates past per_page events", %{conn: conn, team: team} do
      for n <- 1..60, do: :ok = Audit.audit("testing", "page_fill_#{n}", team, %{})

      {:ok, lv, html} = live(conn, ~p"/admin/audit")

      assert html =~ "page 1 of 2"
      assert html =~ "Older →"

      html = lv |> element("a", "Older →") |> render_click()

      assert html =~ "page 2 of 2"
      assert html =~ "← Newer"
    end

    test "filters by topic", %{conn: conn, team: team} do
      :ok = Audit.audit("testing", "only_in_testing_topic", team, %{})

      {:ok, lv, _html} = live(conn, ~p"/admin/audit")

      html = lv |> render_change("filter", %{"topic" => "testing", "q" => ""})

      assert html =~ "only_in_testing_topic"
      refute html =~ "account.create"
    end

    test "searches event names and principal emails", %{conn: conn, team: team} do
      :ok = Audit.audit("testing", "needle_event", team, %{})

      {:ok, lv, _html} = live(conn, ~p"/admin/audit")

      html = lv |> render_change("filter", %{"topic" => "", "q" => "needle"})

      assert html =~ "needle_event"
      refute html =~ "account.create"

      html = lv |> render_change("filter", %{"topic" => "", "q" => team.email})

      assert html =~ "account.create"
    end

    test "scopes to a team via ?team=, including admin actions targeting it", %{
      conn: conn,
      admin: admin,
      team: team
    } do
      # an admin action about the team: admin is principal, team in details
      :ok = Audit.audit("testing", "admin_action", admin, %{team_id: team.id})
      # an unrelated admin event that must not appear when scoped
      :ok = Audit.audit("testing", "unrelated", admin, %{})

      {:ok, _lv, html} = live(conn, ~p"/admin/audit?team=#{team.id}")

      assert html =~ "Showing events concerning"
      assert html =~ team.name
      assert html =~ "admin_action"
      refute html =~ "unrelated"
    end
  end
end
