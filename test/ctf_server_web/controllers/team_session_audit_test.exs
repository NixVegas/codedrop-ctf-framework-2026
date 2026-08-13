defmodule CtfServerWeb.TeamSessionAuditTest do
  use CtfServerWeb.ConnCase, async: true

  import Ecto.Query
  import CtfServer.AccountsFixtures

  alias CtfServer.Audit
  alias CtfServer.Audit.Event
  alias CtfServer.Repo

  defp log_in(conn, email, password) do
    post(conn, ~p"/teams/log_in", %{"team" => %{"email" => email, "password" => password}})
  end

  defp auth_events(team) do
    team
    |> Audit.list_events_for_team()
    |> Enum.filter(&(&1.topic == "auth"))
    |> Enum.map(& &1.event)
    |> Enum.sort()
  end

  test "successful login records attempt and success", %{conn: conn} do
    team = team_fixture()

    log_in(conn, team.email, valid_team_password())

    assert auth_events(team) == ["log_in", "log_in_attempted"]
  end

  test "wrong password records attempt and failure against the team", %{conn: conn} do
    team = team_fixture()

    log_in(conn, team.email, "not the password")

    assert auth_events(team) == ["log_in_attempted", "log_in_failed"]
  end

  test "unknown email records attempt and failure with no principal", %{conn: conn} do
    email = unique_team_email()

    log_in(conn, email, "whatever password")

    events =
      Repo.all(
        from e in Event,
          where: fragment("?->>'email' = ?", e.details, ^email),
          select: {e.event, e.principal_id}
      )
      |> Enum.sort()

    assert events == [{"log_in_attempted", nil}, {"log_in_failed", nil}]
  end

  test "oversized emails are capped in details", %{conn: conn} do
    email = String.duplicate("a", 5000) <> "@example.com"

    log_in(conn, email, "whatever password")

    assert [event | _] =
             Repo.all(
               from e in Event,
                 where: e.event == "log_in_attempted",
                 order_by: [desc: e.occurred_at],
                 limit: 1
             )

    assert String.length(event.details["email"]) == 160
  end
end
