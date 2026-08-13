defmodule CtfServer.AdminTeamManagementTest do
  use CtfServer.DataCase, async: true
  use Oban.Testing, repo: CtfServer.Repo

  alias CtfServer.Accounts
  alias CtfServer.Accounts.TeamToken
  alias CtfServer.Audit
  alias CtfServer.Challenges
  alias CtfServer.Repo

  import CtfServer.AccountsFixtures
  import CtfServer.ChallengesFixtures

  describe "Audit.audit and list_events_for_team/2" do
    test "records events with topic, principal, time, and details" do
      team = team_fixture()
      then = DateTime.utc_now() |> DateTime.add(-3600, :second)

      assert :ok = Audit.audit("testing", "one", team, %{foo: "bar"})
      assert :ok = Audit.audit("testing", "two", team, then, %{})

      events = Audit.list_events_for_team(team)
      one = Enum.find(events, &(&1.event == "one"))
      two = Enum.find(events, &(&1.event == "two"))

      assert one.topic == "testing"
      assert one.principal.id == team.id
      assert one.details == %{"foo" => "bar"}
      assert DateTime.compare(two.occurred_at, then) == :eq
      # newest first
      assert Enum.find_index(events, &(&1 == one)) < Enum.find_index(events, &(&1 == two))
    end

    test "always returns :ok even when the write cannot succeed" do
      team = team_fixture()

      # a pid is not JSON-serializable, so the insert raises internally
      assert :ok = Audit.audit("testing", "boom", team, %{pid: self()})
      # invalid attrs (nil topic) fail changeset validation
      assert :ok = Audit.audit(nil, "boom", team, %{})

      refute Enum.any?(Audit.list_events_for_team(team), &(&1.event == "boom"))
    end

    test "admin actions are listed for the target team via details" do
      team = team_fixture()
      admin = admin_team_fixture()

      assert :ok = Audit.confirm_account(team, admin)

      assert [event | _] = Audit.list_events_for_team(team)
      assert event.topic == "account"
      assert event.event == "confirm"
      assert event.principal.id == admin.id
      assert event.details["team_id"] == team.id
    end

    test "reset_team_password records attempt/succeed/fail" do
      team = team_fixture()

      {:error, _} = Accounts.reset_team_password(team, %{password: "short"})

      events = Audit.list_events_for_team(team) |> Enum.map(& &1.event)
      assert "reset_password_attempted" in events
      assert "reset_password_failed" in events
      refute "reset_password" in events

      failed = Enum.find(Audit.list_events_for_team(team), &(&1.event == "reset_password_failed"))
      assert failed.details["fields"] == ["password"]

      {:ok, _} =
        Accounts.reset_team_password(team, %{
          password: "long enough password",
          password_confirmation: "long enough password"
        })

      events = Audit.list_events_for_team(team) |> Enum.map(& &1.event)
      assert "reset_password" in events
    end

    test "register_team records an account.create event" do
      team = team_fixture()

      assert Enum.any?(
               Audit.list_events_for_team(team),
               &(&1.topic == "account" and &1.event == "create")
             )
    end
  end

  describe "disable_team_login/2 and enable_team_login/2" do
    test "blocks password login and invalidates existing sessions" do
      password = valid_team_password()
      team = team_fixture(%{password: password})
      session_token = Accounts.generate_team_session_token(team)

      {:ok, disabled, [raw_token]} = Accounts.disable_team_login(team)

      assert disabled.disabled_at
      assert raw_token == session_token
      refute Accounts.get_team_by_email_and_password(team.email, password)
      refute Accounts.get_team_by_session_token(session_token)
      refute Repo.get_by(TeamToken, team_id: team.id, context: "session")

      {:ok, enabled} = Accounts.enable_team_login(disabled)

      assert is_nil(enabled.disabled_at)
      assert Accounts.get_team_by_email_and_password(team.email, password)

      events = Audit.list_events_for_team(team) |> Enum.map(& &1.event)
      assert "disable_login" in events
      assert "enable_login" in events
    end
  end

  describe "challenge instance management" do
    setup do
      team = team_fixture()

      attempt =
        challenge_attempt_fixture(%{team_id: team.id, status: :started, port: 2222})

      %{team: team, attempt: attempt}
    end

    test "list_active_attempts_for_team/1 only returns attempts holding resources", %{
      team: team,
      attempt: attempt
    } do
      _completed = challenge_attempt_fixture(%{team_id: team.id, level: 9, status: :completed})

      assert [active] = Challenges.list_active_attempts_for_team(team)
      assert active.id == attempt.id
    end

    test "list_attempts_for_team/1 returns all attempts, active first", %{
      team: team,
      attempt: attempt
    } do
      completed = challenge_attempt_fixture(%{team_id: team.id, level: 9, status: :completed})

      other_team_attempt =
        challenge_attempt_fixture(%{team_id: team_fixture().id, status: :started})

      ids = Challenges.list_attempts_for_team(team) |> Enum.map(& &1.id)

      assert ids == [attempt.id, completed.id]
      refute other_team_attempt.id in ids
    end

    test "force_shutdown_attempt/2 marks deprovisioning and queues teardown", %{
      team: team,
      attempt: attempt
    } do
      admin = admin_team_fixture()

      {:ok, attempt} = Challenges.force_shutdown_attempt(attempt, admin)

      assert attempt.status == :deprovisioning
      assert attempt.earned_score == 0

      assert_enqueued(
        worker: CtfServer.Workers.DeprovisionChallengeAttempt,
        args: %{attempt_id: attempt.id}
      )

      assert [event | _] = Audit.list_events_for_team(team)
      assert event.topic == "challenge"
      assert event.event == "force_shutdown"
      assert event.principal.id == admin.id
      assert event.details["team_id"] == team.id
    end

    test "reset_challenge_attempt_instance/2 queues cleanup-and-delete", %{
      team: team,
      attempt: attempt
    } do
      {:ok, attempt} = Challenges.reset_challenge_attempt_instance(attempt)

      assert attempt.status == :deprovisioning

      assert_enqueued(
        worker: CtfServer.Workers.ResetChallengeAttempt,
        args: %{attempt_id: attempt.id}
      )

      assert [event | _] = Audit.list_events_for_team(team)
      assert event.topic == "challenge"
      assert event.event == "reset"
    end

    test "kill_active_attempts_for_team/2 shuts down everything not already deprovisioning", %{
      team: team,
      attempt: attempt
    } do
      provisioning =
        challenge_attempt_fixture(%{team_id: team.id, level: 8, status: :provisioning})

      _draining =
        challenge_attempt_fixture(%{team_id: team.id, level: 7, status: :deprovisioning})

      {:ok, killed} = Challenges.kill_active_attempts_for_team(team)

      assert Enum.map(killed, & &1.id) |> Enum.sort() ==
               Enum.sort([attempt.id, provisioning.id])

      assert Repo.reload!(attempt).status == :deprovisioning
      assert Repo.reload!(provisioning).status == :deprovisioning
    end
  end
end
