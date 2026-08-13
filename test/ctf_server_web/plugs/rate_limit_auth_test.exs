defmodule CtfServerWeb.Plugs.RateLimitAuthTest do
  # End-to-end coverage for the auth rate limiter (CWE-307): login (controller),
  # registration and password reset (LiveView). async: false, because it shrinks
  # the global :rate_limits config and must not run while other auth tests do.
  use CtfServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CtfServer.AccountsFixtures

  alias CtfServer.Accounts
  alias CtfServer.Repo

  setup do
    original = Application.get_env(:ctf_server, :rate_limits, [])

    Application.put_env(:ctf_server, :rate_limits,
      login: {2, 60_000},
      register: {2, 60_000},
      password_reset: {2, 60_000}
    )

    on_exit(fn -> Application.put_env(:ctf_server, :rate_limits, original) end)
    :ok
  end

  defp from_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp attempt_login(conn) do
    post(conn, ~p"/teams/log_in", %{
      "team" => %{"email" => "nobody@example.com", "password" => "wrong-password"}
    })
  end

  describe "POST /teams/log_in" do
    test "blocks a client once it exceeds the login limit", %{conn: conn} do
      conn = from_ip(conn, {203, 0, 113, 10})

      # The first two attempts are let through (invalid credentials).
      assert Phoenix.Flash.get(attempt_login(conn).assigns.flash, :error) ==
               "Invalid email or password"

      assert Phoenix.Flash.get(attempt_login(conn).assigns.flash, :error) ==
               "Invalid email or password"

      # The third trips the limiter before the credential check runs.
      blocked = attempt_login(conn)
      assert redirected_to(blocked) == ~p"/teams/log_in"
      assert Phoenix.Flash.get(blocked.assigns.flash, :error) =~ "Too many attempts"
      assert [_ | _] = get_resp_header(blocked, "retry-after")
      refute get_session(blocked, :team_token)
    end

    test "a different client IP has its own budget", %{conn: conn} do
      exhaust = from_ip(conn, {203, 0, 113, 11})
      attempt_login(exhaust)
      attempt_login(exhaust)

      assert Phoenix.Flash.get(attempt_login(exhaust).assigns.flash, :error) =~
               "Too many attempts"

      fresh = from_ip(conn, {203, 0, 113, 12})

      assert Phoenix.Flash.get(attempt_login(fresh).assigns.flash, :error) ==
               "Invalid email or password"
    end

    test "post-registration login is not rate limited", %{conn: conn} do
      team = team_fixture()
      conn = from_ip(conn, {203, 0, 113, 13})

      # Exhaust the plain-login budget for this IP.
      attempt_login(conn)
      attempt_login(conn)
      assert Phoenix.Flash.get(attempt_login(conn).assigns.flash, :error) =~ "Too many attempts"

      # A registration-completion login (carries _action) still goes through.
      completed =
        post(conn, ~p"/teams/log_in", %{
          "_action" => "registered",
          "team" => %{"email" => team.email, "password" => valid_team_password()}
        })

      assert redirected_to(completed) == ~p"/dashboard"
    end
  end

  describe "registration LiveView" do
    test "blocks a client that exceeds the registration limit", %{conn: conn} do
      # A distinct client IP (via the trusted-proxy header) isolates this test's
      # counter from the rest of the suite, which registers from 127.0.0.1.
      conn = Plug.Conn.put_req_header(conn, "x-real-ip", "203.0.113.20")
      {:ok, lv, _html} = live(conn, ~p"/teams/register")

      submit = fn n ->
        lv
        |> form("#registration_form",
          team: %{name: "team#{n}", email: "reg#{n}@example.com", password: valid_team_password()}
        )
        |> render_submit()
      end

      # Two registrations are allowed; the third is throttled before hashing.
      submit.(1)
      submit.(2)
      assert submit.(3) =~ "Too many attempts"
    end
  end

  describe "forgot-password LiveView" do
    test "stops sending reset emails once the limit is hit", %{conn: conn} do
      team = team_fixture()
      # Distinct client IP so the counter is isolated from other reset tests.
      conn = Plug.Conn.put_req_header(conn, "x-real-ip", "203.0.113.21")

      send_reset = fn ->
        {:ok, lv, _html} = live(conn, ~p"/teams/reset_password")

        lv
        |> form("#reset_password_form", team: %{email: team.email})
        |> render_submit()
      end

      # Two allowed submits mint two reset tokens; the third is denied silently.
      send_reset.()
      send_reset.()
      send_reset.()

      assert length(Repo.all(Accounts.TeamToken)) == 2
    end
  end
end
