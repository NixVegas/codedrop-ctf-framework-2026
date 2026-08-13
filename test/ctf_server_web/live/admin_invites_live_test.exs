defmodule CtfServerWeb.AdminInvitesLiveTest do
  use CtfServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CtfServer.AccountsFixtures

  test "non-admin is redirected", %{conn: conn} do
    conn = log_in_team(conn, team_fixture())
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/admin/invites")
  end

  test "admin generates codes and sees them listed", %{conn: conn} do
    conn = log_in_team(conn, admin_team_fixture())
    {:ok, lv, _html} = live(conn, ~p"/admin/invites")

    html =
      lv
      |> form("#gen_form", %{"count" => "3", "words" => "3"})
      |> render_submit()

    assert html =~ "New codes"
    assert CtfServer.Accounts.count_invite_codes().total == 3

    codes = CtfServer.Accounts.list_invite_codes()
    assert Enum.any?(codes, &(render(lv) =~ &1.code))
  end

  test "admin generating with a zero count shows an error and creates no codes", %{conn: conn} do
    conn = log_in_team(conn, admin_team_fixture())
    {:ok, lv, _html} = live(conn, ~p"/admin/invites")

    html =
      lv
      |> form("#gen_form", %{"count" => "0", "words" => "3"})
      |> render_submit()

    assert html =~ "Enter a positive whole number"
    assert CtfServer.Accounts.count_invite_codes().total == 0
  end

  test "admin generating with a blank count shows an error and creates no codes", %{conn: conn} do
    conn = log_in_team(conn, admin_team_fixture())
    {:ok, lv, _html} = live(conn, ~p"/admin/invites")

    html =
      lv
      |> form("#gen_form", %{"count" => "", "words" => "3"})
      |> render_submit()

    assert html =~ "Enter a positive whole number"
    assert CtfServer.Accounts.count_invite_codes().total == 0
  end
end
