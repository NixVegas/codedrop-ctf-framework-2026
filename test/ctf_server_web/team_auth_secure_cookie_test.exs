defmodule CtfServerWeb.TeamAuthSecureCookieTest do
  # The remember-me cookie carries the Secure flag only when :secure_cookies is
  # on (prod), keeping the 60-day token off plaintext HTTP (CWE-614). async:
  # false because it toggles the global :secure_cookies config.
  use CtfServerWeb.ConnCase, async: false

  import CtfServer.AccountsFixtures

  @cookie "_ctf_server_web_team_remember_me"

  setup do
    %{team: team_fixture()}
  end

  defp log_in_with_remember_me(conn, team) do
    post(conn, ~p"/teams/log_in", %{
      "team" => %{
        "email" => team.email,
        "password" => valid_team_password(),
        "remember_me" => "true"
      }
    })
  end

  test "the remember-me cookie is not Secure by default (dev/test over HTTP)", %{
    conn: conn,
    team: team
  } do
    conn = log_in_with_remember_me(conn, team)
    assert conn.resp_cookies[@cookie]
    refute conn.resp_cookies[@cookie][:secure]
  end

  test "the remember-me cookie is Secure when :secure_cookies is enabled", %{
    conn: conn,
    team: team
  } do
    Application.put_env(:ctf_server, :secure_cookies, true)
    on_exit(fn -> Application.put_env(:ctf_server, :secure_cookies, false) end)

    conn = log_in_with_remember_me(conn, team)
    assert conn.resp_cookies[@cookie][:secure]
  end
end
