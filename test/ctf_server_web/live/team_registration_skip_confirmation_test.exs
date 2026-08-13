defmodule CtfServerWeb.TeamRegistrationSkipConfirmationTest do
  # Toggles the global :skip_account_confirmation setting, so it must not run
  # concurrently with other tests that register teams.
  use CtfServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias CtfServer.Accounts

  import CtfServer.AccountsFixtures

  # Regression test for https://github.com/NixVegas/ctf-server/issues/10:
  # with confirmation skipped, registration must not touch the mailer at all.
  test "registration confirms the team and sends no email", %{conn: conn} do
    previous = Application.get_env(:ctf_server, :skip_account_confirmation)
    Application.put_env(:ctf_server, :skip_account_confirmation, true)
    on_exit(fn -> Application.put_env(:ctf_server, :skip_account_confirmation, previous) end)

    {:ok, lv, _html} = live(conn, ~p"/teams/register")

    email = unique_team_email()

    form =
      form(lv, "#registration_form",
        team: %{name: "Fresh Team", email: email, password: valid_team_password()}
      )

    render_submit(form)
    conn = follow_trigger_action(form, conn)

    assert redirected_to(conn) == ~p"/dashboard"

    team = Accounts.get_team_by_email(email)
    assert team.confirmed_at
    assert_no_email_sent()
  end
end
