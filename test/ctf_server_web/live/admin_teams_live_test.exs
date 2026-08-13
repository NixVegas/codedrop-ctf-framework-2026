defmodule CtfServerWeb.AdminTeamsLiveTest do
  use CtfServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CtfServer.AccountsFixtures

  alias CtfServer.Accounts

  describe "access control" do
    test "redirects anonymous users to the login page", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/admin/teams")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/teams/log_in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects non-admin teams to the dashboard", %{conn: conn} do
      team = team_fixture()
      conn = conn |> log_in_team(team) |> get(~p"/admin/teams")

      assert redirected_to(conn) == ~p"/dashboard"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must be an admin to access this page."
    end
  end

  describe "team management" do
    setup %{conn: conn} do
      admin = admin_team_fixture()
      %{conn: log_in_team(conn, admin), admin: admin}
    end

    test "lists teams", %{conn: conn, admin: admin} do
      team = team_fixture()

      {:ok, _lv, html} = live(conn, ~p"/admin/teams")

      assert html =~ "Team management"
      assert html =~ admin.name
      assert html =~ team.name
      assert html =~ team.email
    end

    test "registers a confirmed team", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/teams")

      email = unique_team_email()

      html =
        lv
        |> form("#admin_registration_form",
          team: %{name: "Manual Team", email: email, password: valid_team_password()}
        )
        |> render_submit()

      assert html =~ "Manual Team"
      assert html =~ email

      team = Accounts.get_team_by_email(email)
      assert team.confirmed_at
      assert Accounts.get_team_by_email_and_password(email, valid_team_password())
    end

    test "renders errors for invalid registration data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/teams")

      html =
        lv
        |> form("#admin_registration_form",
          team: %{name: "", email: "not an email", password: "short"}
        )
        |> render_submit()

      assert html =~ "must have the @ sign and no spaces"
      assert html =~ "should be at least 12 character"
    end

    test "confirms an unconfirmed team", %{conn: conn} do
      team = team_fixture()
      assert is_nil(team.confirmed_at)

      {:ok, lv, _html} = live(conn, ~p"/admin/teams")

      lv
      |> element("#teams a[phx-value-id='#{team.id}']", "Confirm")
      |> render_click()

      assert Accounts.get_team!(team.id).confirmed_at
    end

    test "generates a working one-time password reset code", %{conn: conn} do
      team = team_fixture()

      {:ok, lv, _html} = live(conn, ~p"/admin/teams")

      html =
        lv
        |> element("#teams a[phx-value-id='#{team.id}']", "Reset code")
        |> render_click()

      assert [_, reset_path] = Regex.run(~r{(/teams/reset_password/[\w-]+)}, html)

      "/teams/reset_password/" <> code = reset_path
      assert reset_team = Accounts.get_team_by_reset_password_token(code)
      assert reset_team.id == team.id

      # The code drives the ordinary reset password flow.
      reset_conn = build_conn()
      {:ok, reset_lv, _html} = live(reset_conn, reset_path)

      {:ok, _conn} =
        reset_lv
        |> form("#reset_password_form",
          team: %{
            password: "brand new password",
            password_confirmation: "brand new password"
          }
        )
        |> render_submit()
        |> follow_redirect(reset_conn, ~p"/teams/log_in")

      assert Accounts.get_team_by_email_and_password(team.email, "brand new password")
      refute Accounts.get_team_by_reset_password_token(code)
    end
  end
end
