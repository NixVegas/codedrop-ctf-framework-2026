defmodule CtfServerWeb.TeamRegistrationLiveTest do
  use CtfServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CtfServer.AccountsFixtures
  alias CtfServer.Competition

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/teams/register")

      assert html =~ "Register"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_team(team_fixture())
        |> live(~p"/teams/register")
        |> follow_redirect(conn, ~p"/dashboard")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/teams/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(team: %{"email" => "with spaces", "password" => "too short"})

      assert result =~ "Register"
      assert result =~ "must have the @ sign and no spaces"
      assert result =~ "should be at least 12 character"
    end
  end

  describe "register team" do
    test "creates account and logs the team in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/teams/register")

      email = unique_team_email()
      form = form(lv, "#registration_form", team: valid_team_attributes(email: email))
      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/dashboard"

      # Now do a logged in request and assert on the menu
      conn = get(conn, "/")
      response = html_response(conn, 200)
      assert response =~ email
      assert response =~ "Settings"
      assert response =~ "Log out"
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/teams/register")

      team = team_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          team: %{"email" => team.email, "password" => "valid_password", "name" => team.name}
        )
        # |> open_browser()
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  describe "registration window gating" do
    test "with the default (open) window, the form renders", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/teams/register")
      assert html =~ "registration_form"
      refute html =~ "Registration is closed"
    end

    test "before start, the form is absent and a closed message shows", %{conn: conn} do
      {:ok, _} =
        Competition.update(Competition.get(), %{
          starts_at: ~U[2999-01-01 00:00:00Z],
          ends_at: nil
        })

      {:ok, _lv, html} = live(conn, ~p"/teams/register")
      refute html =~ "registration_form"
      assert html =~ "Registration is closed"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/teams/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/teams/log_in")

      assert login_html =~ "Log in"
    end
  end

  describe "invite code gating" do
    setup do
      Application.put_env(:ctf_server, :require_invite_codes, true)
      Application.put_env(:ctf_server, :local_networks, ["10.7.0.0/16"])

      on_exit(fn ->
        Application.put_env(:ctf_server, :require_invite_codes, false)
        Application.put_env(:ctf_server, :local_networks, [])
      end)

      :ok
    end

    test "remote client sees the invite field and cannot register without a code", %{conn: conn} do
      conn = Plug.Conn.put_req_header(conn, "x-real-ip", "203.0.113.9")
      {:ok, lv, html} = live(conn, ~p"/teams/register")
      assert html =~ "Invite code"

      lv
      |> form("#registration_form",
        team: %{name: "R", email: "r@example.com", password: "hello world!"}
      )
      |> render_submit()

      assert render(lv) =~ "invite code is not valid"
    end

    test "remote client with a valid code registers", %{conn: conn} do
      {:ok, [code]} = CtfServer.Accounts.generate_invite_codes(1)
      conn = Plug.Conn.put_req_header(conn, "x-real-ip", "203.0.113.9")
      {:ok, lv, _html} = live(conn, ~p"/teams/register")

      lv
      |> form("#registration_form",
        team: %{name: "R", email: "r@example.com", password: "hello world!", invite_code: code}
      )
      |> render_submit()

      assert CtfServer.Accounts.get_team_by_email("r@example.com").registered_remote
    end

    test "local client does not see the invite field", %{conn: conn} do
      conn = Plug.Conn.put_req_header(conn, "x-real-ip", "10.7.0.5")
      {:ok, _lv, html} = live(conn, ~p"/teams/register")
      refute html =~ "Invite code"
    end

    test "typed invite code round-trips through validate", %{conn: conn} do
      conn = Plug.Conn.put_req_header(conn, "x-real-ip", "203.0.113.9")
      {:ok, lv, _html} = live(conn, ~p"/teams/register")

      html =
        lv
        |> element("#registration_form")
        |> render_change(team: %{"invite_code" => "ABC123"})

      assert html =~ ~s(value="ABC123")
    end
  end
end
