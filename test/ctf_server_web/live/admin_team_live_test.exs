defmodule CtfServerWeb.AdminTeamLiveTest do
  use CtfServerWeb.ConnCase, async: true
  use Oban.Testing, repo: CtfServer.Repo

  import Phoenix.LiveViewTest
  import CtfServer.AccountsFixtures
  import CtfServer.ChallengesFixtures

  alias CtfServer.Accounts
  alias CtfServer.Audit
  alias CtfServer.Repo

  setup %{conn: conn} do
    admin = admin_team_fixture()
    team = team_fixture()
    %{conn: log_in_team(conn, admin), admin: admin, team: team}
  end

  describe "access control" do
    test "redirects non-admin teams", %{team: team} do
      conn = build_conn() |> log_in_team(team) |> get(~p"/admin/teams/#{team}")

      assert redirected_to(conn) == ~p"/dashboard"
    end

    test "redirects for an unknown team id", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> live(~p"/admin/teams/#{Ecto.UUID.generate()}")
        |> follow_redirect(conn, ~p"/admin/teams")

      assert html =~ "Team not found."
    end
  end

  describe "team detail" do
    test "shows team info, an audit-trail link, and all attempts", %{conn: conn, team: team} do
      active = challenge_attempt_fixture(%{team_id: team.id, status: :started, port: 2222})

      completed =
        challenge_attempt_fixture(%{
          team_id: team.id,
          level: 4,
          status: :completed,
          earned_score: 100
        })

      {:ok, _lv, html} = live(conn, ~p"/admin/teams/#{team}")

      assert html =~ team.name
      assert html =~ team.email
      # the audit trail lives on its own page, scoped to this team
      assert html =~ ~p"/admin/audit?team=#{team.id}"
      # both active and completed attempts are listed
      assert html =~ "#{active.group} / #{active.level}"
      assert html =~ "#{completed.group} / #{completed.level}"
      assert html =~ "completed"
    end

    test "shows each attempt's flag so staff can verify submissions", %{conn: conn, team: team} do
      challenge_attempt_fixture(%{
        team_id: team.id,
        status: :started,
        flag: %{"flag" => "Nix{admin-visible}"}
      })

      {:ok, _lv, html} = live(conn, ~p"/admin/teams/#{team}")

      assert html =~ "Nix{admin-visible}"
    end

    test "completed attempts can be reset but not force shut down", %{conn: conn, team: team} do
      challenge_attempt_fixture(%{team_id: team.id, status: :completed, earned_score: 100})

      {:ok, lv, _html} = live(conn, ~p"/admin/teams/#{team}")

      refute has_element?(lv, "#attempts a[phx-click=force_shutdown]")
      assert has_element?(lv, "#attempts a[phx-click=reset_instance]")
    end

    test "index rows navigate to the detail page", %{conn: conn, team: team} do
      {:ok, lv, _html} = live(conn, ~p"/admin/teams")

      lv
      |> element("#teams-#{team.id} td:first-child")
      |> render_click()

      assert_redirect(lv, ~p"/admin/teams/#{team}")
    end

    test "confirms the team", %{conn: conn, team: team} do
      {:ok, lv, _html} = live(conn, ~p"/admin/teams/#{team}")

      html = lv |> element("a", "Confirm") |> render_click()

      assert html =~ "confirmed"
      assert Accounts.get_team!(team.id).confirmed_at
    end

    test "generates a reset code", %{conn: conn, team: team, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/admin/teams/#{team}")

      html = lv |> element("a", "Reset code") |> render_click()

      assert [_, code] = Regex.run(~r{/teams/reset_password/([\w-]+)}, html)
      assert Accounts.get_team_by_reset_password_token(code).id == team.id

      assert [event | _] = Audit.list_events_for_team(team)
      assert event.event == "create_reset_code"
      assert event.principal.id == admin.id
    end
  end

  describe "instance actions" do
    test "force shutdown marks the attempt deprovisioning and queues teardown", %{
      conn: conn,
      team: team
    } do
      attempt = challenge_attempt_fixture(%{team_id: team.id, status: :started, port: 2222})

      {:ok, lv, _html} = live(conn, ~p"/admin/teams/#{team}")

      html = lv |> element("a", "Force shutdown") |> render_click()

      assert html =~ "deprovisioning"
      assert Repo.reload!(attempt).status == :deprovisioning

      assert_enqueued(
        worker: CtfServer.Workers.DeprovisionChallengeAttempt,
        args: %{attempt_id: attempt.id}
      )
    end

    test "reset queues the reset worker", %{conn: conn, team: team} do
      attempt = challenge_attempt_fixture(%{team_id: team.id, status: :started, port: 2222})

      {:ok, lv, _html} = live(conn, ~p"/admin/teams/#{team}")

      lv |> element("a[phx-click=reset_instance]") |> render_click()

      assert Repo.reload!(attempt).status == :deprovisioning

      assert_enqueued(
        worker: CtfServer.Workers.ResetChallengeAttempt,
        args: %{attempt_id: attempt.id}
      )
    end

    test "a force-shut-down (completed) attempt can still be reset", %{conn: conn, team: team} do
      # force shutdown leaves the attempt :completed with score 0
      attempt =
        challenge_attempt_fixture(%{team_id: team.id, status: :completed, earned_score: 0})

      {:ok, lv, _html} = live(conn, ~p"/admin/teams/#{team}")

      lv |> element("a[phx-click=reset_instance]") |> render_click()

      assert Repo.reload!(attempt).status == :deprovisioning

      assert_enqueued(
        worker: CtfServer.Workers.ResetChallengeAttempt,
        args: %{attempt_id: attempt.id}
      )
    end

    test "reset worker is a no-op when the attempt is already gone" do
      # The cleanup-and-delete path shells out to virsh, so it is exercised
      # in dev/staging rather than here; the worker must at least tolerate
      # an attempt deleted before the job runs (e.g. double reset).
      assert :ok =
               perform_job(CtfServer.Workers.ResetChallengeAttempt, %{
                 "attempt_id" => Ecto.UUID.generate()
               })
    end
  end

  describe "nuke" do
    test "disables login, kicks sessions, and kills instances", %{
      conn: conn,
      team: team,
      admin: admin
    } do
      password = valid_team_password()
      session_token = Accounts.generate_team_session_token(team)
      attempt = challenge_attempt_fixture(%{team_id: team.id, status: :started, port: 2222})

      {:ok, lv, _html} = live(conn, ~p"/admin/teams/#{team}")

      html = lv |> element("a", "Nuke") |> render_click()

      assert html =~ "nuked"
      assert html =~ "Re-enable login"

      team = Accounts.get_team!(team.id)
      assert team.disabled_at
      refute Accounts.get_team_by_email_and_password(team.email, password)
      refute Accounts.get_team_by_session_token(session_token)
      assert Repo.reload!(attempt).status == :deprovisioning

      assert_enqueued(
        worker: CtfServer.Workers.DeprovisionChallengeAttempt,
        args: %{attempt_id: attempt.id}
      )

      events = Audit.list_events_for_team(team)
      nuke_event = Enum.find(events, &(&1.event == "disable_login"))
      assert nuke_event.principal.id == admin.id
    end

    test "re-enable login restores access", %{conn: conn, team: team} do
      {:ok, _team, _tokens} = Accounts.disable_team_login(team)

      {:ok, lv, html} = live(conn, ~p"/admin/teams/#{team}")

      assert html =~ "Re-enable login"
      refute html =~ ">Nuke<"

      html = lv |> element("a", "Re-enable login") |> render_click()

      assert html =~ "Login re-enabled"
      assert is_nil(Accounts.get_team!(team.id).disabled_at)
    end

    test "admins cannot be nuked", %{conn: conn, admin: admin} do
      other_admin = admin_team_fixture()

      {:ok, _lv, html} = live(conn, ~p"/admin/teams/#{other_admin}")

      refute html =~ ">Nuke<"

      # Belt and braces: the server-side handler also refuses.
      {:ok, lv, _html} = live(conn, ~p"/admin/teams/#{admin}")
      html = render_click(lv, "nuke", %{})

      assert html =~ "Admin accounts cannot be nuked."
      assert is_nil(Accounts.get_team!(admin.id).disabled_at)
    end
  end
end
