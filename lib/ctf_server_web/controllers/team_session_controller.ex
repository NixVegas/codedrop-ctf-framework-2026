defmodule CtfServerWeb.TeamSessionController do
  use CtfServerWeb, :controller

  alias CtfServer.Accounts
  alias CtfServerWeb.TeamAuth

  def create(conn, %{"_action" => "registered"} = params) do
    create(conn, params, "Account created successfully!")
  end

  def create(conn, %{"_action" => "password_updated"} = params) do
    conn
    |> put_session(:team_return_to, ~p"/teams/settings")
    |> create(params, "Password updated successfully!")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  defp create(conn, %{"team" => team_params}, info) do
    %{"email" => email, "password" => password} = team_params

    known_team = Accounts.get_team_by_email(email)
    CtfServer.Audit.log_in_attempted(known_team, email)

    if team = Accounts.get_team_by_email_and_password(email, password) do
      CtfServer.Audit.log_in(team)

      conn
      |> put_flash(:info, info)
      |> TeamAuth.log_in_team(team, team_params)
    else
      CtfServer.Audit.log_in_failed(known_team, email)

      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/teams/log_in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> TeamAuth.log_out_team()
  end
end
