defmodule CtfServerWeb.ChallengeLiveAuditTest do
  use CtfServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CtfServer.AccountsFixtures
  import CtfServer.ChallengesFixtures

  alias CtfServer.Audit

  setup %{conn: conn} do
    team = team_fixture()
    challenge_attempt_fixture(%{team_id: team.id, group: "basic-nix", level: 1, status: :started})
    %{conn: log_in_team(conn, team), team: team}
  end

  defp submit_flag(conn, flag) do
    {:ok, lv, _html} = live(conn, ~p"/challenge/basic-nix/1")

    lv
    |> form("form", flag: %{flag: flag})
    |> render_submit()
  end

  defp events_for(team, event) do
    team
    |> Audit.list_events_for_team()
    |> Enum.filter(&(&1.topic == "challenge" and &1.event == event))
  end

  test "malformed flags record submit_flag and a malformed failure", %{conn: conn, team: team} do
    html = submit_flag(conn, "not even close")

    assert html =~ "Flag must be in Nix{&lt;flag&gt;} form!"

    assert [submitted] = events_for(team, "submit_flag")
    assert submitted.details["flag"] == "not even close"

    assert [failed] = events_for(team, "submit_flag_failed")
    assert failed.details["reason"] == "malformed"
  end

  test "wrong flags record submit_flag and an incorrect failure", %{conn: conn, team: team} do
    html = submit_flag(conn, "Nix{wrong}")

    assert html =~ "Flag incorrect!"

    assert [failed] = events_for(team, "submit_flag_failed")
    assert failed.details["reason"] == "incorrect"
    assert failed.details["flag"] == "Nix{wrong}"
  end

  test "correct flags record submit_flag and complete with the score", %{conn: conn, team: team} do
    correct =
      :crypto.hash(:sha256, CtfServer.Challenges.BasicNix1.generate_seed(team))
      |> Base.encode16(case: :lower)

    {:error, {:live_redirect, %{to: "/dashboard"}}} = submit_flag(conn, "Nix{#{correct}}")

    assert [_submitted] = events_for(team, "submit_flag")
    assert [] = events_for(team, "submit_flag_failed")

    assert [completed] = events_for(team, "complete")
    assert completed.details["score"] > 0
  end

  test "a lowercase nix{ prefix is accepted", %{conn: conn, team: team} do
    correct =
      :crypto.hash(:sha256, CtfServer.Challenges.BasicNix1.generate_seed(team))
      |> Base.encode16(case: :lower)

    {:error, {:live_redirect, %{to: "/dashboard"}}} = submit_flag(conn, "nix{#{correct}}")

    assert [] = events_for(team, "submit_flag_failed")
    assert [completed] = events_for(team, "complete")
    assert completed.details["score"] > 0
  end

  test "an uppercase NIX{ prefix is well-formed, not malformed", %{conn: conn, team: team} do
    # A wrong-but-well-formed flag is scored (incorrect), proving the prefix is
    # matched case-insensitively rather than rejected as malformed.
    html = submit_flag(conn, "NIX{wrong}")

    assert html =~ "Flag incorrect!"
    assert [failed] = events_for(team, "submit_flag_failed")
    assert failed.details["reason"] == "incorrect"
  end
end
